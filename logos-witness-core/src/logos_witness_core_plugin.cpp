#include "logos_witness_core_plugin.h"
#include "reference.pb.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>

#include "exif_strip.h"
#include "geohash.h"

namespace {

constexpr quint32 kSchemaVersion = 1;
constexpr int     kGeohashPrecision = 8;
// SPEC §2: single global topic for v0. Trailing `/proto` names the
// wire encoding per LIP-23.
constexpr const char* kDeliveryTopic = "/logos-witness/1/inscriptions/proto";

QVariantMap referenceToVariant(const logos::witness::v1::Reference& r) {
    QVariantMap m;
    m.insert("schema_version", static_cast<quint32>(r.schema_version()));
    m.insert("content_hash",
             QByteArray(r.content_hash().data(),
                        static_cast<int>(r.content_hash().size())).toHex());
    m.insert("timestamp", static_cast<qulonglong>(r.timestamp()));
    m.insert("geohash", QString::fromStdString(r.geohash()));
    m.insert("storage_cid", QString::fromStdString(r.storage_cid()));
    return m;
}

QVariantMap errorMap(const QString& msg) {
    QVariantMap m;
    m.insert("ok", false);
    m.insert("error", msg);
    return m;
}

QString buildStorageConfig(const QString& dataDir) {
    QJsonObject cfg;
    cfg["log-level"] = QString("INFO");
    cfg["data-dir"] = dataDir;
    // libstorage's StorageConf uses scalar listen-ip + listen-port (not
    // a multiaddr `listen-addrs` array). The
    // storage_module_interface.h docstring is misleading on this — see
    // logos-storage-nim/storage/conf.nim for the authoritative names.
    cfg["listen-ip"] = QString("0.0.0.0");
    cfg["listen-port"] = 0;  // random free port
    cfg["nat"] = QString("any");

    int apiPort = qEnvironmentVariableIntValue("LOGOS_STORAGE_API_PORT");
    if (apiPort <= 0) apiPort = 8081;
    cfg["api-bindaddr"] = QString("127.0.0.1");
    cfg["api-port"] = apiPort;

    int discPort = qEnvironmentVariableIntValue("LOGOS_STORAGE_DISC_PORT");
    if (discPort <= 0) discPort = 8091;
    cfg["disc-port"] = discPort;

    cfg["repo-kind"] = QString("fs");
    cfg["storage-quota"] = QJsonValue(static_cast<qint64>(21474836480));
    cfg["block-ttl"] = QString("4w2d");
    cfg["max-peers"] = 160;
    cfg["num-threads"] = 0;

    // Join the public Logos Storage test network. Without
    // `bootstrap-node`, our `storage_module` instances only know
    // themselves — same-host alice + bob never discover each other,
    // so `fetchPhoto(cid)` from bob never finds alice's blob.
    // SPRs are pinned to the test-network bootstrap set at
    // https://github.com/logos-co/node-configs/blob/master/storage_config_test.json
    // (snapshot 2026-05-18). Update when that file does — the SPRs
    // are operator-managed by status.im / logos.dev infra, not
    // baked into libstorage. Cross-host fetch over the public
    // network is the canonical Phase 5 path; same-host two-instance
    // dogfood rides the same DHT.
    QJsonArray bootstrap;
    bootstrap.append(QString(
        "spr:CiUIAhIhA-VlcoiRm02KyIzrcTP-ljFpzTljfBRRKTIvhMIwqBqWEgIDARpJ"
        "CicAJQgCEiED5WVyiJGbTYrIjOtxM_6WMWnNOWN8FFEpMi-EwjCoGpYQs8n8wQYa"
        "CwoJBHTKubmRAnU6GgsKCQR0yrm5kQJ1OipHMEUCIQDwUNsfReB4ty7JFS5WVQ6n"
        "1fcko89qVAOfQEHixa03rgIgan2-uFNDT-r4s9TOkLe9YBkCbsRWYCHGGVJ25rLj0QE"));
    bootstrap.append(QString(
        "spr:CiUIAhIhApIj9p6zJDRbw2NoCo-tj98Y760YbppRiEpGIE1yGaMzEgIDARpJ"
        "CicAJQgCEiECkiP2nrMkNFvDY2gKj62P3xjvrRhumlGISkYgTXIZozMQvcz8wQYa"
        "CwoJBAWhF3WRAnVEGgsKCQQFoRd1kQJ1RCpGMEQCIFZB84O_nzPNuViqEGRL1vJT"
        "jHBJ-i5ZDgFL5XZxm4HAAiB8rbLHkUdFfWdiOmlencYVn0noSMRHzn4lJYoShuVzlw"));
    bootstrap.append(QString(
        "spr:CiUIAhIhApqRgeWRPSXocTS9RFkQmwTZRG-Cdt7UR2N7POoz606ZEgIDARpJ"
        "CicAJQgCEiECmpGB5ZE9JehxNL1EWRCbBNlEb4J23tRHY3s86jPrTpkQj8_8wQYa"
        "CwoJBAXfEfiRAnVOGgsKCQQF3xH4kQJ1TipGMEQCIGWJMsF57N1iIEQgTH7IrVOg"
        "Egv0J2P2v3jvQr5Cjy-RAiAy4aiZ8QtyDvCfl_K_w6SyZ9csFGkRNTpirq_M_QNgKw"));
    cfg["bootstrap-node"] = bootstrap;

    return QString::fromUtf8(QJsonDocument(cfg).toJson(QJsonDocument::Compact));
}

}  // namespace

LogosWitnessCorePlugin::LogosWitnessCorePlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "LogosWitnessCorePlugin: Constructor";
}

LogosWitnessCorePlugin::~LogosWitnessCorePlugin()
{
    delete delivery_;
    delete storage_;
    delete logos;
}

void LogosWitnessCorePlugin::initLogos(LogosAPI* logosAPIInstance) {
    logosAPI = logosAPIInstance;
    if (logos) { delete logos; }
    logos = logosAPI ? new LogosModules(logosAPI) : nullptr;
    // storage_module init is deferred to _ensureStorage() — it may not be
    // loaded yet when initLogos runs.
}

bool LogosWitnessCorePlugin::_ensureStorage()
{
    if (storageReady_) return true;
    if (!logos || !logos->api) {
        qWarning() << "_ensureStorage: no LogosAPI";
        return false;
    }

    // storage_module is declared as a dependency in metadata.json, so
    // logos-cpp-generator emits a typed `m_logos->storage_module` accessor
    // and the framework binds it on first use. No explicit loadPlugin call
    // is needed (and `core_manager.loadPlugin` from a consumer module is
    // not reachable as a remote replica anyway — every call times out).
    storage_ = new StorageClient(logos, this);
    QString cfg = buildStorageConfig(cacheDir() + "/storage");
    qInfo() << "_ensureStorage: calling storage_module init...";
    if (!storage_->init(cfg)) {
        qWarning() << "_ensureStorage: storage_module init failed";
        delete storage_;
        storage_ = nullptr;
        return false;
    }
    qInfo() << "_ensureStorage: calling storage_module start...";
    if (!storage_->start()) {
        qWarning() << "_ensureStorage: storage_module start failed";
        delete storage_;
        storage_ = nullptr;
        return false;
    }
    storageReady_ = true;
    qInfo() << "_ensureStorage: storage_module ready";
    return true;
}

bool LogosWitnessCorePlugin::_ensureDelivery()
{
    if (deliveryReady_) return true;
    if (!logos || !logos->api) {
        qWarning() << "_ensureDelivery: no LogosAPI";
        return false;
    }

    delivery_ = new DeliveryClient(logos, this);
    connect(delivery_, &DeliveryClient::referenceReceived,
            this,      &LogosWitnessCorePlugin::_onDeliveryReceived);

    qInfo() << "_ensureDelivery: subscribing to" << kDeliveryTopic;
    if (!delivery_->init(QString::fromUtf8(kDeliveryTopic))) {
        qWarning() << "_ensureDelivery: init failed";
        delete delivery_;
        delivery_ = nullptr;
        return false;
    }
    deliveryReady_ = true;
    qInfo() << "_ensureDelivery: delivery_module ready";
    return true;
}

void LogosWitnessCorePlugin::_onDeliveryReceived(const QByteArray& refBytes)
{
    logos::witness::v1::Reference ref;
    if (!ref.ParseFromArray(refBytes.constData(), refBytes.size())) {
        qWarning() << "_onDeliveryReceived: protobuf parse failed";
        return;
    }
    const QByteArray hash(ref.content_hash().data(),
                          static_cast<int>(ref.content_hash().size()));
    if (knownHashes_.contains(hash)) {
        // Local submit fan-back, or a peer re-broadcast of a ref we
        // already have. SPEC §2: content_hash is the dedupe key.
        return;
    }
    knownHashes_.insert(hash);
    store_.append(refBytes);
    qInfo() << "_onDeliveryReceived: new ref from peer, content_hash="
            << hash.toHex().left(16);
    emit referenceObserved(refBytes);
}

QString LogosWitnessCorePlugin::cacheDir() const
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (dir.isEmpty()) dir = QDir::currentPath() + "/.cache/logos-witness-core";
    return dir;
}

QVariantMap LogosWitnessCorePlugin::submitPhoto(const QString& filePath,
                                                 const QString& timestamp,
                                                 const QString& geohash) {
    if (filePath.isEmpty())             return errorMap("filePath is empty");
    if (geohash.size() != kGeohashPrecision)
        return errorMap("geohash must be precision 8 (exactly 8 chars)");

    bool ok = false;
    const qint64 ts = timestamp.toLongLong(&ok);
    if (!ok || ts <= 0) return errorMap("timestamp must be positive unix seconds (decimal string)");

    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly)) return errorMap("could not open file: " + filePath);
    const QByteArray content = f.readAll();
    f.close();
    if (content.isEmpty()) return errorMap("empty file: " + filePath);

    // SPEC §7.1 / §2: content_hash is sha256 of the *stripped* bytes.
    const auto stripped = logos::witness::strip_jpeg(
        std::string(content.constData(), static_cast<size_t>(content.size())));
    if (!stripped.ok) {
        return errorMap("strip_jpeg failed: " + QString::fromStdString(stripped.error));
    }
    const QByteArray strippedBytes(stripped.bytes.data(),
                                   static_cast<int>(stripped.bytes.size()));
    const QByteArray hash = QCryptographicHash::hash(strippedBytes,
                                                     QCryptographicHash::Sha256);

    // Upload stripped bytes to Storage. Fail-closed: if storage is not
    // reachable, the user sees an error rather than a silent ok=true with
    // no CID (which previously hid Phase 5 wiring bugs for ~80 s of UI
    // freeze + a wrong-looking "success").
    if (!_ensureStorage()) {
        return errorMap("storage_module not available — see logs for init/start failure");
    }
    auto uploadResult = storage_->upload(strippedBytes, cacheDir());
    if (!uploadResult.ok) {
        return errorMap("storage upload failed: " + uploadResult.error);
    }
    const QString cid = uploadResult.cid;
    if (!storage_->exists(cid)) {
        qWarning() << "submitPhoto: uploaded cid not found in local store:" << cid;
    } else {
        qInfo() << "submitPhoto: cid stored locally:" << cid;
    }

    logos::witness::v1::Reference ref;
    ref.set_schema_version(kSchemaVersion);
    ref.set_content_hash(std::string(hash.constData(), static_cast<size_t>(hash.size())));
    ref.set_timestamp(static_cast<std::uint64_t>(ts));
    ref.set_geohash(geohash.toStdString());
    ref.set_storage_cid(cid.toStdString());

    std::string buf;
    if (!ref.SerializeToString(&buf)) return errorMap("protobuf serialize failed");
    const QByteArray refBytes(buf.data(), static_cast<int>(buf.size()));
    store_.append(refBytes);
    // Pre-seed the dedupe set so Delivery's fan-back of our own publish
    // doesn't re-process the ref. The content_hash here is over the
    // stripped bytes (set above as the protobuf field).
    knownHashes_.insert(hash);

    // Publish to the live feed. The ref is durable in the local store
    // either way, so a publish failure is not fatal — but it IS visible
    // to the caller: the return shape carries `delivery_ok` so the UI
    // can render a "saved locally, not broadcast" affordance. No silent
    // fallbacks (project memory).
    bool deliveryOk = false;
    QString deliveryErr;
    if (_ensureDelivery()) {
        deliveryOk = delivery_->publish(refBytes);
        if (!deliveryOk) deliveryErr = "delivery_module.send failed";
    } else {
        deliveryErr = "delivery_module not ready";
    }
    if (!deliveryOk) {
        qWarning() << "submitPhoto: delivery publish failed:" << deliveryErr
                   << "(ref kept locally)";
    }

    emit referenceObserved(refBytes);

    QVariantMap r;
    r.insert("ok", true);
    r.insert("content_hash", hash.toHex());
    r.insert("storage_cid", cid);
    r.insert("delivery_ok", deliveryOk);
    if (!deliveryOk) r.insert("delivery_error", deliveryErr);
    return r;
}

QVariantList LogosWitnessCorePlugin::listInscriptions(const QVariantMap& filter) {
    Q_UNUSED(filter);
    QVariantList out;
    const auto snap = store_.snapshot();
    out.reserve(snap.size());
    for (const QByteArray& bytes : snap) {
        logos::witness::v1::Reference ref;
        if (!ref.ParseFromArray(bytes.constData(), bytes.size())) continue;
        out.append(referenceToVariant(ref));
    }
    return out;
}

QVariantMap LogosWitnessCorePlugin::fetchPhoto(const QString& cid) {
    if (cid.isEmpty()) return errorMap("cid is empty");
    if (!_ensureStorage()) {
        return errorMap("storage not ready");
    }

    auto result = storage_->download(cid, cacheDir());
    if (!result.ok) {
        return errorMap("fetchPhoto failed: " + result.error);
    }

    // Return as base64 data URL so the sandboxed QML engine can render it
    // without needing file:// access (which basecamp's DenyAll blocks).
    QString b64 = QString::fromLatin1(result.data.toBase64());
    QVariantMap r;
    r.insert("ok", true);
    r.insert("data_url", "data:image/jpeg;base64," + b64);
    return r;
}

QVariantList LogosWitnessCorePlugin::listInscriptions() {
    return listInscriptions(QVariantMap{});
}

QVariantMap LogosWitnessCorePlugin::flushBatch() {
    // Stub: chain inscription is deferred to Phase 7. Refs stay in the
    // in-memory store; nothing to drain.
    QVariantMap r;
    r.insert("ok", true);
    r.insert("flushed", 0);
    r.insert("note", "stub: zone-sdk inscribe wired in Phase 7");
    return r;
}

void LogosWitnessCorePlugin::subscribeFeed() {
    // Idempotent opt-in to the live Delivery feed. The first call brings
    // up the delivery_module node + subscribes to the witness topic; the
    // first inbound message after that fires _onDeliveryReceived →
    // referenceObserved. Calling submitPhoto without first calling
    // subscribeFeed is still fine — submitPhoto lazy-inits the same
    // path. The UI is expected to call subscribeFeed during init so the
    // subscriber is up before any peer broadcasts arrive.
    _ensureDelivery();
}

QVariantMap LogosWitnessCorePlugin::decodeReference(const QByteArray& refBytes) {
    if (refBytes.isEmpty()) return errorMap("refBytes is empty");
    logos::witness::v1::Reference ref;
    if (!ref.ParseFromArray(refBytes.constData(), refBytes.size()))
        return errorMap("protobuf parse failed");

    QVariantMap r = referenceToVariant(ref);
    r.insert("ok", true);
    return r;
}

QVariantMap LogosWitnessCorePlugin::decodeGeohash(const QString& geohash) {
    const auto res = logos::witness::geohash::decode(geohash.toStdString());
    if (!res.ok) {
        if (geohash.isEmpty()) return errorMap("geohash is empty");
        return errorMap(QString("invalid geohash char at %1").arg(res.errorIndex));
    }
    QVariantMap r;
    r.insert("ok", true);
    r.insert("latitude",  res.latitude);
    r.insert("longitude", res.longitude);
    return r;
}
