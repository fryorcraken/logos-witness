#include "storage_client.h"
#include "logos_sdk.h"

#include <QDebug>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QTimer>
#include <QUrl>
#include <QUuid>
#include <QVariant>

StorageClient::StorageClient(LogosModules* logos, QObject* parent)
    : QObject(parent), logos_(logos)
{
}

StorageClient::~StorageClient()
{
    if (started_) {
        stop();
        destroy();
    }
}

bool StorageClient::init(const QString& configJson)
{
    if (!logos_) return false;
    return logos_->storage_module.init(configJson);
}

// ---------------------------------------------------------------------------
// start: async, completion via "storageStart" event. Block here so callers
// inside Q_INVOKABLE methods can treat it as synchronous.
// ---------------------------------------------------------------------------
bool StorageClient::start()
{
    if (!logos_) return false;

    bool startOk = false;
    QString startErr;
    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);

    logos_->storage_module.on("storageStart", [&](const QVariantList& data) {
        startOk = !data.isEmpty() && data[0].toBool();
        if (!startOk && data.size() >= 2) startErr = data[1].toString();
        timer.stop();
        loop.quit();
    });
    QObject::connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit);

    if (!logos_->storage_module.start()) {
        qWarning() << "StorageClient: storage_module.start() returned false";
        return false;
    }
    timer.start(30000);
    loop.exec();

    if (!startOk) {
        qWarning() << "StorageClient: start failed:"
                   << (startErr.isEmpty() ? QStringLiteral("timeout") : startErr);
        return false;
    }

    started_ = true;

    // Log identity + space so the user can see the node is alive.
    LogosResult pid = logos_->storage_module.peerId();
    LogosResult spr = logos_->storage_module.spr();
    LogosResult sp  = logos_->storage_module.space();
    qInfo() << "StorageClient: started; peerId="
            << (pid.success ? pid.getString() : QStringLiteral("?"))
            << "spr=" << (spr.success ? spr.getString().left(40) + QStringLiteral("...")
                                      : QStringLiteral("?"));
    if (sp.success) {
        qInfo() << "StorageClient: quota used/max bytes="
                << sp.getValue<int>("quotaUsedBytes")
                << "/" << sp.getValue<int>("quotaMaxBytes");
    }

    emit storageReady();
    return true;
}

void StorageClient::stop()
{
    if (!logos_) return;
    logos_->storage_module.stop();
    started_ = false;
}

void StorageClient::destroy()
{
    if (!logos_) return;
    logos_->storage_module.destroy();
}

// ---------------------------------------------------------------------------
// Upload: write stripped bytes to a tempfile, call uploadUrl, wait for the
// storageUploadDone event carrying our sessionId.
// ---------------------------------------------------------------------------
StorageClient::UploadResult StorageClient::upload(const QByteArray& data,
                                                  const QString& cacheDir)
{
    UploadResult r;
    if (!started_) { r.error = "storage not ready"; return r; }
    if (!logos_)   { r.error = "no LogosModules"; return r; }

    QDir dir(cacheDir);
    if (!dir.exists()) dir.mkpath(".");
    QString tmpPath = dir.filePath("upload_" + QUuid::createUuid().toString(QUuid::WithoutBraces) + ".jpg");
    QFile f(tmpPath);
    if (!f.open(QIODevice::WriteOnly)) {
        r.error = "cannot write tempfile: " + tmpPath;
        return r;
    }
    f.write(data);
    f.close();

    LogosResult initResult = logos_->storage_module.uploadUrl(
        QVariant::fromValue(QUrl::fromLocalFile(tmpPath)));
    if (!initResult.success) {
        QFile::remove(tmpPath);
        r.error = "uploadUrl failed: " + initResult.error.toString();
        return r;
    }
    const QString sessionId = initResult.getString();
    if (sessionId.isEmpty()) {
        QFile::remove(tmpPath);
        r.error = "uploadUrl returned empty sessionId";
        return r;
    }

    bool gotEvent = false;
    bool success = false;
    QString payload;
    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);

    logos_->storage_module.on("storageUploadDone", [&](const QVariantList& evData) {
        if (evData.size() < 2) return;
        if (evData[1].toString() != sessionId) return;
        gotEvent = true;
        success = evData[0].toBool();
        if (evData.size() >= 3) payload = evData[2].toString();
        timer.stop();
        loop.quit();
    });
    QObject::connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit);

    timer.start(60000);
    loop.exec();
    QFile::remove(tmpPath);

    if (!gotEvent) {
        r.error = "upload timed out waiting for storageUploadDone";
        return r;
    }
    if (!success) {
        r.error = payload.isEmpty() ? QStringLiteral("upload failed") : payload;
        return r;
    }

    r.ok = true;
    r.cid = payload;
    return r;
}

// ---------------------------------------------------------------------------
// Download: streams a CID into a local file, waits for storageDownloadDone,
// reads the file back into memory.
//
// Two-shot: first try `local=true` (read from this node's own repo without
// hitting the DHT — fast path for blobs we uploaded), then fall back to
// `local=false` (DHT lookup — needed for peer-supplied blobs). libstorage's
// "Failed to download the manifest" error on `local=false` for a CID we
// ourselves just uploaded is the canonical symptom: the manifest IS in our
// repo but the DHT roundtrip hasn't found anyone advertising it yet.
// ---------------------------------------------------------------------------

namespace {
// Per-attempt: kicks off one downloadToUrl call (local true or false) and
// blocks until the storageDownloadDone event for the session arrives or the
// timer fires. Returns true on success; populates errorMsg on failure.
struct DownloadAttempt {
    bool ok = false;
    QString error;
};

DownloadAttempt _downloadOnce(LogosModules* logos, const QString& cid,
                              const QUrl& dest, bool local, int timeoutMs)
{
    DownloadAttempt r;
    LogosResult initResult = logos->storage_module.downloadToUrl(
        cid, QVariant::fromValue(dest), local);
    if (!initResult.success) {
        r.error = "downloadToUrl failed: " + initResult.error.toString();
        return r;
    }
    const QString sessionId = initResult.getString();
    if (sessionId.isEmpty()) {
        r.error = "downloadToUrl returned empty sessionId";
        return r;
    }

    bool gotEvent = false;
    bool success = false;
    QString errorMsg;
    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);

    logos->storage_module.on("storageDownloadDone", [&](const QVariantList& evData) {
        if (evData.size() < 2) return;
        if (evData[1].toString() != sessionId) return;
        gotEvent = true;
        success = evData[0].toBool();
        if (!success && evData.size() >= 3) errorMsg = evData[2].toString();
        timer.stop();
        loop.quit();
    });
    QObject::connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit);

    timer.start(timeoutMs);
    loop.exec();

    if (!gotEvent) {
        r.error = "download timed out waiting for storageDownloadDone";
        return r;
    }
    if (!success) {
        r.error = errorMsg.isEmpty() ? QStringLiteral("download failed") : errorMsg;
        return r;
    }
    r.ok = true;
    return r;
}
}  // anonymous namespace

StorageClient::DownloadResult StorageClient::download(const QString& cid,
                                                      const QString& cacheDir)
{
    DownloadResult r;
    if (!started_) { r.error = "storage not ready"; return r; }
    if (!logos_)   { r.error = "no LogosModules"; return r; }

    QDir dir(cacheDir);
    if (!dir.exists()) dir.mkpath(".");
    // Per-attempt unique paths. If the 5 s local timeout fires while
    // the underlying libstorage download is still running, the local
    // session may still write `destPath` after we've moved on — a
    // network attempt writing the same path would then race the
    // straggler write, producing a corrupt JPEG. Distinct paths
    // mean we read the winner cleanly; the loser's bytes (if any)
    // are orphaned and reaped by the OS / cleaned up below.
    const QString localPath = dir.filePath(cid + ".local.jpg");
    const QString netPath   = dir.filePath(cid + ".net.jpg");
    const QString finalPath = dir.filePath(cid + ".jpg");

    // Fast path: local repo. Short timeout (5s) — a true local hit
    // returns near-instantly; failure means "not in local repo, try
    // the network."
    auto localAttempt = _downloadOnce(
        logos_, cid, QUrl::fromLocalFile(localPath), /*local=*/true, 5000);
    QString winnerPath;
    if (localAttempt.ok) {
        winnerPath = localPath;
    } else {
        // Network fallback. Longer timeout for DHT lookup + transfer.
        auto netAttempt = _downloadOnce(
            logos_, cid, QUrl::fromLocalFile(netPath), /*local=*/false, 60000);
        if (!netAttempt.ok) {
            // Best-effort cleanup of either attempt's partial bytes.
            QFile::remove(localPath);
            QFile::remove(netPath);
            r.error = "local: " + localAttempt.error
                    + " | network: " + netAttempt.error;
            return r;
        }
        winnerPath = netPath;
    }

    QFile f(winnerPath);
    if (!f.open(QIODevice::ReadOnly)) {
        r.error = "downloaded file not readable: " + winnerPath;
        return r;
    }
    r.data = f.readAll();
    f.close();

    // Publish under the canonical path the caller expects, then drop
    // both attempt files. The straggler (if any) lands in an orphan
    // we'll prune; the rename ensures concurrent callers for the
    // same CID see a coherent file at `finalPath`.
    QFile::remove(finalPath);
    QFile::rename(winnerPath, finalPath);
    QFile::remove(localPath);
    QFile::remove(netPath);

    r.ok = true;
    return r;
}

bool StorageClient::exists(const QString& cid)
{
    if (!started_ || !logos_) return false;
    LogosResult result = logos_->storage_module.exists(cid);
    return result.success && result.value.toBool();
}
