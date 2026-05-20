#include "logos_witness_ui_qml_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMetaObject>
#include <QRunnable>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>

#include <dlfcn.h>

namespace {
constexpr int kRefreshIntervalMs = 5000;
constexpr const char* kCoreModule = "logos_witness_core";

// Translate core's listInscriptions return shape (QVariantList of
// QVariantMap) into the same shape we hand to QML's auto-syncing
// `refs` PROP. core's snapshot already matches; we pass through.
// Lenient QVariant→QVariantList. QtRO sometimes hands back the
// payload as a typed list, sometimes as a QJsonArray-shaped variant
// (depending on whether the source declared the slot return type
// with a registered metatype). Just call toList() — it handles both,
// returns an empty list on truly-unconvertible input.
QVariantList normaliseRefs(const QVariant& raw)
{
    if (!raw.isValid()) return {};
    const QVariantList out = raw.toList();
    if (out.isEmpty() && raw.userType() != QMetaType::QVariantList) {
        qWarning() << "logos_witness_ui_qml: listInscriptions returned"
                   << "unexpected QVariant type:" << raw.typeName();
    }
    return out;
}

// Lenient QVariant→QVariantMap (same reasoning).
QVariantMap normaliseMap(const QVariant& raw)
{
    if (!raw.isValid()) return {};
    return raw.toMap();
}
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
    if (m_logosAPI) return;
    m_logosAPI = api;
    m_logos = new LogosModules(api);
    setBackend(this);

    // Cache the client. getClient() is the LogosAPI-side dispatcher
    // for any module-to-module call; it's safe to keep a pointer to
    // (the underlying replica is acquired on first call).
    m_coreClient = api->getClient(kCoreModule);

    // Kick subscribeFeed off-thread so initLogos doesn't block on a
    // cold core. ui-host calls initLogos from its main thread; we
    // don't own that thread. The worker calls subscribeFeed +
    // populates the initial refs list, then hands off to the timer.
    QThreadPool::globalInstance()->start(std::function<void()>([this]() {
        // subscribeFeed has no return; ignore reply value.
        if (m_coreClient) {
            m_coreClient->invokeRemoteMethod(
                kCoreModule, "subscribeFeed", QVariantList{});
        }
        // First refresh: populate refs PROP + deliveryReady PROP.
        QMetaObject::invokeMethod(this, "_refreshFromCore",
                                  Qt::QueuedConnection);
    }));

    _subscribeToCoreEvents();

    // Set up the 5 s polling Timer. Cheap (snapshot in core's
    // in-memory store + a bool read) and the backstop for the push
    // channel above — covers the case where the event subscription
    // is dropped silently.
    m_refreshTimer = new QTimer(this);
    m_refreshTimer->setInterval(kRefreshIntervalMs);
    connect(m_refreshTimer, &QTimer::timeout,
            this, &LogosWitnessUiQmlPlugin::_refreshFromCore);
    m_refreshTimer->start();

    setBackendStatus(QStringLiteral("ready"));
    qInfo() << "logos_witness_ui_qml: hybrid backend ready";
}

void LogosWitnessUiQmlPlugin::_subscribeToCoreEvents()
{
    if (!m_logosAPI || !m_coreClient) return;
    // Core emits `referenceObserved(QByteArray refBytes)` whenever
    // submitPhoto succeeds locally or delivery_module hands a new
    // peer ref to subscribeFeed. We don't care about the bytes here —
    // _refreshFromCore() pulls a full list snapshot and pushes it
    // into the PROP, so the push channel just triggers a sooner-than-
    // 5 s refresh. requestObject is potentially blocking (resolves a
    // QtRO replica), so do it on a worker; the 5 s polling timer
    // covers us if subscription fails.
    QThreadPool::globalInstance()->start(std::function<void()>([this]() {
        if (!m_coreClient) return;
        LogosObject* obj = m_coreClient->requestObject(kCoreModule);
        if (!obj) {
            qWarning() << "logos_witness_ui_qml: requestObject(core) "
                          "failed; falling back to 5 s polling";
            return;
        }
        m_coreObject = obj;
        obj->onEvent(
            QStringLiteral("referenceObserved"),
            [this](const QString& /*evt*/, const QVariantList& /*data*/) {
                QMetaObject::invokeMethod(this, "_refreshFromCore",
                                          Qt::QueuedConnection);
            });
    }));
}

void LogosWitnessUiQmlPlugin::_refreshFromCore()
{
    if (!m_coreClient) return;
    const QVariant rawRefs = m_coreClient->invokeRemoteMethod(
        kCoreModule, "listInscriptions", QVariantList{});
    setRefs(normaliseRefs(rawRefs));

    const QVariant rawDelivery = m_coreClient->invokeRemoteMethod(
        kCoreModule, "deliveryReady", QVariantList{});
    setDeliveryReady(rawDelivery.toBool());
}

QVariantMap LogosWitnessUiQmlPlugin::decodeGeohash(QString geohash)
{
    // Cheap (no I/O) — runs synchronously on the backend thread.
    // Core's decodeGeohash returns the same QVariantMap shape we
    // forward to QML.
    if (!m_coreClient) {
        QVariantMap r;
        r["ok"] = false;
        r["error"] = QStringLiteral("backend not initialised");
        return r;
    }
    const QVariant raw = m_coreClient->invokeRemoteMethod(
        kCoreModule, "decodeGeohash", QVariantList{geohash});
    if (raw.canConvert<QVariantMap>()) return raw.toMap();
    QVariantMap r;
    r["ok"] = false;
    r["error"] = QStringLiteral("decodeGeohash returned non-map");
    return r;
}

void LogosWitnessUiQmlPlugin::submitPhotoAsync(QString localId,
                                                QString filePath,
                                                QString timestamp,
                                                QString geohash)
{
    // Run the blocking submit on a worker so the backend's own thread
    // stays responsive for fetch / decodeGeohash / refresh ticks.
    QThreadPool::globalInstance()->start(std::function<void()>(
        [this, localId, filePath, timestamp, geohash]() {
        if (!m_coreClient) {
            _emitSubmitDone(localId, {}, {}, false, false,
                            QStringLiteral("backend not initialised"));
            return;
        }
        const QVariant raw = m_coreClient->invokeRemoteMethod(
            kCoreModule, "submitPhoto",
            QVariantList{filePath, timestamp, geohash});
        if (!raw.canConvert<QVariantMap>()) {
            _emitSubmitDone(localId, {}, {}, false, false,
                            QStringLiteral("submitPhoto returned non-map"));
            return;
        }
        const QVariantMap m = raw.toMap();
        const bool ok = m.value("ok").toBool();
        const QString cid = m.value("storage_cid").toString();
        const QString contentHash = m.value("content_hash").toString();
        // Match core's soft-warning shape: deliveryOk defaults true
        // when the key is absent (older builds) and false when present
        // and false. submitPhoto only sets delivery_ok=false on
        // upload-success / broadcast-fail.
        const QVariant rawDel = m.value("delivery_ok");
        const bool deliveryOk = rawDel.isValid() ? rawDel.toBool() : true;
        QString error = m.value("error").toString();
        if (ok && !deliveryOk && error.isEmpty()) {
            error = m.value("delivery_error").toString();
        }
        _emitSubmitDone(localId, contentHash, cid, ok, deliveryOk, error);
        // Push a refresh so the new ref (with its CID) lands in the
        // PROP without waiting for the next poll tick.
        QMetaObject::invokeMethod(this, "_refreshFromCore",
                                  Qt::QueuedConnection);
    }));
}

void LogosWitnessUiQmlPlugin::fetchPhotoAsync(QString cid)
{
    QThreadPool::globalInstance()->start(std::function<void()>(
        [this, cid]() {
        if (!m_coreClient) {
            _emitPhotoFailed(cid, QStringLiteral("backend not initialised"));
            return;
        }
        const QVariant raw = m_coreClient->invokeRemoteMethod(
            kCoreModule, "fetchPhoto", QVariantList{cid});
        if (!raw.canConvert<QVariantMap>()) {
            _emitPhotoFailed(cid, QStringLiteral("fetchPhoto returned non-map"));
            return;
        }
        const QVariantMap m = raw.toMap();
        if (!m.value("ok").toBool()) {
            _emitPhotoFailed(cid, m.value("error").toString());
            return;
        }
        // Core currently returns a base64 data URL string; strip the
        // header and decode to raw bytes for the QtRO QByteArray
        // payload. Once core exposes a `data_bytes` field we can
        // switch to that and drop the decode round-trip.
        const QString dataUrl = m.value("data_url").toString();
        const int comma = dataUrl.indexOf(QLatin1Char(','));
        if (comma < 0) {
            _emitPhotoFailed(cid, QStringLiteral("fetchPhoto returned malformed data_url"));
            return;
        }
        const QByteArray bytes = QByteArray::fromBase64(
            dataUrl.mid(comma + 1).toLatin1());
        if (bytes.isEmpty()) {
            _emitPhotoFailed(cid, QStringLiteral("fetchPhoto: empty bytes after base64 decode"));
            return;
        }
        _emitPhotoReady(cid, bytes);
    }));
}

// Re-post worker-thread emissions onto the backend thread so the QtRO
// source's auto-generated emit machinery runs where it expects to.
void LogosWitnessUiQmlPlugin::_emitSubmitDone(QString localId,
                                              QString contentHash,
                                              QString storageCid,
                                              bool ok, bool deliveryOk,
                                              QString error)
{
    QMetaObject::invokeMethod(this, [=]() {
        emit submitDone(localId, contentHash, storageCid, ok, deliveryOk, error);
    }, Qt::QueuedConnection);
}

void LogosWitnessUiQmlPlugin::_emitPhotoReady(QString cid, QByteArray bytes)
{
    QMetaObject::invokeMethod(this, [=]() {
        emit photoReady(cid, bytes);
    }, Qt::QueuedConnection);
}

void LogosWitnessUiQmlPlugin::_emitPhotoFailed(QString cid, QString error)
{
    QMetaObject::invokeMethod(this, [=]() {
        emit photoFailed(cid, error);
    }, Qt::QueuedConnection);
}

// _coreCall / _coreCallList are reserved helpers for future sync calls
// from the backend thread. Currently unused (every existing call site
// inlines invokeRemoteMethod for clarity); kept on the header so a
// follow-up can drop in a typed-accessor migration without touching
// the public surface.
QVariantMap LogosWitnessUiQmlPlugin::_coreCall(const QString& method,
                                                const QVariantList& args)
{
    if (!m_coreClient) return {};
    const QVariant raw = m_coreClient->invokeRemoteMethod(
        kCoreModule, method, args);
    return raw.canConvert<QVariantMap>() ? raw.toMap() : QVariantMap{};
}

QVariantList LogosWitnessUiQmlPlugin::_coreCallList(const QString& method,
                                                    const QVariantList& args)
{
    if (!m_coreClient) return {};
    const QVariant raw = m_coreClient->invokeRemoteMethod(
        kCoreModule, method, args);
    return normaliseRefs(raw);
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
    if (!src.open(QIODevice::ReadOnly)) {
        return QStringLiteral("error:cannot open file: ")
               + path + QStringLiteral(" (") + src.errorString() + QStringLiteral(")");
    }
    const QByteArray bytes = src.readAll();
    src.close();
    if (bytes.isEmpty()) {
        return QStringLiteral("error:file is empty: ") + path;
    }

    // Cache key off the bytes — picking the same photo twice hits the
    // existing file instead of rewriting it. Suffix matches the
    // input where possible (preserves QML's image-format autodetect).
    const QByteArray digest = QCryptographicHash::hash(
        bytes, QCryptographicHash::Sha256).toHex().left(16);
    QString suffix = QFileInfo(path).suffix().toLower();
    if (suffix.isEmpty()) suffix = QStringLiteral("jpg");

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
    const QString outPath = cacheDir + QStringLiteral("/") + digest
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
    }
    return QStringLiteral("file://") + outPath;
}
