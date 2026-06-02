#include "logos_witness_ui_qml_plugin.h"
#include "logos_api.h"
#include "logos_sdk.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileInfoList>
#include <QMetaObject>
#include <QTimer>
#include <QUrl>
#include <QVariantList>

#include <dlfcn.h>

namespace {
constexpr int kRefreshIntervalMs = 5000;
// loadLocalPhotoUrl size + cache caps. 200 MB single-file ceiling
// matches what a 24MP RAW or panorama JPEG plausibly comes in at;
// anything beyond is almost certainly a wrong file pick and we
// shouldn't OOM ui-host trying to readAll() it. 1 GB total cache
// holds ~250 typical 4 MB photos before LRU eviction kicks in.
constexpr qint64 kMaxPreviewBytes = 200LL * 1024 * 1024;
constexpr qint64 kMaxPreviewCacheBytes = 1024LL * 1024 * 1024;
}

LogosWitnessUiQmlPlugin::LogosWitnessUiQmlPlugin(QObject* parent)
    : LogosWitnessUiQmlSimpleSource(parent)
{
}

LogosWitnessUiQmlPlugin::~LogosWitnessUiQmlPlugin()
{
    if (m_refreshTimer) m_refreshTimer->stop();
    delete m_logos;
}

void LogosWitnessUiQmlPlugin::initLogos(LogosAPI* api)
{
    // Assign the inherited PluginInterface::logosAPI field (NOT a private
    // member, NOT a global — interface.h declares `LogosAPI* logosAPI`).
    // The framework's cross-module event plumbing reads this field; the
    // core plugin already sets it, and a third-party-plugin repro
    // (fryorcraken/ui-core-core@7cebe86) confirmed cross-module IPC on
    // basecamp 0.1.2 only works once it's assigned. dlipicar confirmed
    // this is the intended contract in logos-basecamp#150. We use it as
    // the init-guard too, so there's no separate m_logosAPI.
    if (logosAPI) return;
    logosAPI = api;
    m_logos = new LogosModules(api);

    setBackend(this);

    // Idempotent opt-in to the cross-instance reference feed. Core
    // lazy-inits delivery_module on this call; first invocation may
    // take a beat for the QtRO replica handshake.
    m_logos->logos_witness_core.subscribeFeed();

    // Push channel: subscribe to `referenceObserved` so we refresh
    // the timeline immediately when a new ref lands (local submit or
    // peer broadcast). The typed accessor's on() is the documented
    // event-listener shape — matches m_logos->delivery_module.on(...)
    // in logos-delivery-demo.
    m_logos->logos_witness_core.on(
        QStringLiteral("referenceObserved"),
        [this](const QVariantList& /*data*/) {
            QMetaObject::invokeMethod(this, "_refreshFromCore",
                                      Qt::QueuedConnection);
        });

    // First refresh: populate refs + deliveryReady PROPs.
    _refreshFromCore();

    // 5 s polling Timer for refs + readiness. Backstop for the push
    // channel above — covers the case where the event subscription
    // drops silently or core flips state without emitting.
    m_refreshTimer = new QTimer(this);
    m_refreshTimer->setInterval(kRefreshIntervalMs);
    connect(m_refreshTimer, &QTimer::timeout,
            this, &LogosWitnessUiQmlPlugin::_refreshFromCore);
    m_refreshTimer->start();

    setBackendStatus(QStringLiteral("ready"));
    qInfo() << "logos_witness_ui_qml: hybrid backend ready";
}

void LogosWitnessUiQmlPlugin::_refreshFromCore()
{
    if (!m_logos) return;
    setRefs(m_logos->logos_witness_core.listInscriptions());
    setDeliveryReady(m_logos->logos_witness_core.deliveryReady());
    setStorageReady(m_logos->logos_witness_core.storageReady());
}

QVariantMap LogosWitnessUiQmlPlugin::decodeGeohash(QString geohash)
{
    if (!m_logos) {
        QVariantMap r;
        r["ok"] = false;
        r["error"] = QStringLiteral("backend not initialised");
        return r;
    }
    return m_logos->logos_witness_core.decodeGeohash(geohash);
}

void LogosWitnessUiQmlPlugin::submitPhotoAsync(QString localId,
                                                QString filePath,
                                                QString timestamp,
                                                QString geohash)
{
    if (!m_logos) {
        emit submitDone(localId, {}, {}, false, false,
                        QStringLiteral("backend not initialised"));
        return;
    }
    const QVariantMap m = m_logos->logos_witness_core.submitPhoto(
        filePath, timestamp, geohash);
    if (m.isEmpty()) {
        emit submitDone(localId, {}, {}, false, false,
                        QStringLiteral("submitPhoto returned no result"));
        return;
    }
    const bool ok = m.value("ok").toBool();
    const QString cid = m.value("storage_cid").toString();
    const QString contentHash = m.value("content_hash").toString();
    // Match core's soft-warning shape: deliveryOk defaults true when
    // the key is absent (older builds) and false when present and
    // false. submitPhoto only sets delivery_ok=false on
    // upload-success / broadcast-fail.
    const QVariant rawDel = m.value("delivery_ok");
    const bool deliveryOk = rawDel.isValid() ? rawDel.toBool() : true;
    QString error = m.value("error").toString();
    if (ok && !deliveryOk && error.isEmpty()) {
        error = m.value("delivery_error").toString();
    }
    emit submitDone(localId, contentHash, cid, ok, deliveryOk, error);
    // Push a refresh so the new ref lands in the PROP without
    // waiting for the next poll tick.
    _refreshFromCore();
}

void LogosWitnessUiQmlPlugin::fetchPhotoAsync(QString cid)
{
    if (!m_logos) {
        emit photoFailed(cid, QStringLiteral("backend not initialised"));
        return;
    }
    const QVariantMap m = m_logos->logos_witness_core.fetchPhoto(cid);
    if (m.isEmpty()) {
        emit photoFailed(cid, QStringLiteral("fetchPhoto returned no result"));
        return;
    }
    if (!m.value("ok").toBool()) {
        emit photoFailed(cid, m.value("error").toString());
        return;
    }
    // Core currently returns a base64 data URL string; strip the
    // header and decode to raw bytes, then materialise as a file://
    // URL under the plugin's runtime install dir (the only
    // filesystem root QML's interceptor allows).
    const QString dataUrl = m.value("data_url").toString();
    const int comma = dataUrl.indexOf(QLatin1Char(','));
    if (comma < 0) {
        emit photoFailed(cid, QStringLiteral("fetchPhoto returned malformed data_url"));
        return;
    }
    const QByteArray bytes = QByteArray::fromBase64(
        dataUrl.mid(comma + 1).toLatin1());
    if (bytes.isEmpty()) {
        emit photoFailed(cid, QStringLiteral("fetchPhoto: empty bytes after base64 decode"));
        return;
    }
    // Storage CIDs are content-addressed already; use the CID as the
    // cache key. JPEG suffix — SPEC §7 standardises on JPEG.
    const QString url = _cacheBytesUnderPluginDir(
        bytes, cid, QStringLiteral("jpg"));
    if (url.startsWith(QStringLiteral("error:"))) {
        emit photoFailed(cid, url.mid(QStringLiteral("error:").size()));
        return;
    }
    emit photoReady(cid, url);
}

// Find the directory this .so was loaded from. basecamp's
// RestrictedUrlInterceptor whitelists `file://` only under each
// module's plugin path (the runtime-installed copy of the .lgx
// contents), so we *must* materialise the preview file there for QML
// `Image.source: file://...` to be honoured. dladdr maps any address
// inside the .so back to its on-disk path.
static QString pluginInstallDir(const void* addrInThisSo)
{
    Dl_info info{};
    if (dladdr(addrInThisSo, &info) == 0 || !info.dli_fname) return {};
    return QFileInfo(QString::fromLocal8Bit(info.dli_fname)).absolutePath();
}

// Keep the preview cache under kMaxPreviewCacheBytes by deleting
// the oldest-mtime entries first. Best-effort: a delete failure
// (file locked by readback, perms, …) is logged and skipped, never
// fails the caller — running over budget is preferable to refusing
// the new photo.
static void evictPreviewCache(const QString& cacheDir,
                              qint64 budgetBytes)
{
    QDir d(cacheDir);
    if (!d.exists()) return;
    QFileInfoList entries = d.entryInfoList(
        QDir::Files | QDir::NoDotAndDotDot, QDir::Time | QDir::Reversed);
    qint64 total = 0;
    for (const QFileInfo& fi : entries) total += fi.size();
    if (total <= budgetBytes) return;
    for (const QFileInfo& fi : entries) {
        if (total <= budgetBytes) break;
        const qint64 sz = fi.size();
        if (QFile::remove(fi.absoluteFilePath())) {
            total -= sz;
        } else {
            qWarning() << "logos_witness_ui_qml: preview-cache evict"
                       << "failed to delete" << fi.absoluteFilePath();
        }
    }
}

QString LogosWitnessUiQmlPlugin::loadLocalPhotoUrl(QString filePath)
{
    // Strip any `file://` scheme the QML picker handed us — QFile
    // expects a plain path.
    QString path = filePath;
    if (path.startsWith(QStringLiteral("file://"))) {
        path = QUrl(filePath).toLocalFile();
    }
    QFile src(path);
    if (!src.exists()) {
        return QStringLiteral("error:file not found: ") + path;
    }
    // Size cap BEFORE open so a user pointing at a multi-GB blob
    // can't OOM us via readAll().
    const qint64 size = QFileInfo(path).size();
    if (size > kMaxPreviewBytes) {
        return QStringLiteral("error:file too large: ") + path
             + QStringLiteral(" (") + QString::number(size)
             + QStringLiteral(" bytes; max is ")
             + QString::number(kMaxPreviewBytes) + QStringLiteral(")");
    }
    if (!src.open(QIODevice::ReadOnly)) {
        return QStringLiteral("error:cannot open file: ")
               + path + QStringLiteral(" (") + src.errorString() + QStringLiteral(")");
    }
    const QByteArray bytes = src.readAll();
    src.close();
    if (bytes.isEmpty()) {
        return QStringLiteral("error:file is empty: ") + path;
    }

    // Cache key off the bytes (SHA-256 prefix) so picking the same
    // photo twice hits the existing file. Suffix matches the input
    // where possible (preserves QML's image-format autodetect).
    const QString key = QString::fromLatin1(QCryptographicHash::hash(
        bytes, QCryptographicHash::Sha256).toHex().left(16));
    QString suffix = QFileInfo(path).suffix().toLower();
    if (suffix.isEmpty()) suffix = QStringLiteral("jpg");
    return _cacheBytesUnderPluginDir(bytes, key, suffix);
}

// Materialise `bytes` as a file under the plugin's runtime install
// dir and return a `file://` URL the QML engine accepts. Shared
// between loadLocalPhotoUrl (Submit preview, key = SHA-256 prefix of
// bytes) and fetchPhotoAsync (storage fetch, key = CID).
QString LogosWitnessUiQmlPlugin::_cacheBytesUnderPluginDir(
    const QByteArray& bytes, const QString& key, const QString& suffix)
{
    static const void* anchor =
        reinterpret_cast<const void*>(&LogosWitnessUiQmlPlugin::loadLocalPhotoUrl);
    const QString dir = pluginInstallDir(anchor);
    if (dir.isEmpty()) {
        return QStringLiteral("error:could not resolve plugin install dir "
                              "(dladdr returned no info)");
    }
    const QString cacheDir = dir + QStringLiteral("/preview-cache");
    if (!QDir().mkpath(cacheDir)) {
        return QStringLiteral("error:could not create preview cache: ") + cacheDir;
    }
    const QString outPath = cacheDir + QStringLiteral("/") + key
                          + QStringLiteral(".") + suffix;
    if (!QFileInfo::exists(outPath)) {
        QFile out(outPath);
        if (!out.open(QIODevice::WriteOnly)) {
            return QStringLiteral("error:cannot write preview file: ")
                   + outPath + QStringLiteral(" (") + out.errorString() + QStringLiteral(")");
        }
        if (out.write(bytes) != bytes.size()) {
            out.close();
            return QStringLiteral("error:short write to preview file: ") + outPath;
        }
        out.close();
        // Cache is LRU-bounded — every fresh write trims the dir to
        // budget. Cheap on the common path (a single readdir + size
        // sum), expensive only when we actually need to evict.
        evictPreviewCache(cacheDir, kMaxPreviewCacheBytes);
    }
    return QStringLiteral("file://") + outPath;
}
