#include "logos_witness_core_plugin.h"
#include "reference.pb.h"

#include <QCryptographicHash>
#include <QDebug>
#include <QFile>

#include "logos_api.h"
#include "logos_api_client.h"

namespace {

constexpr quint32 kSchemaVersion = 1;
constexpr int     kGeohashPrecision = 8;

QVariantMap referenceToVariant(const logos::witness::v1::Reference& r) {
    QVariantMap m;
    m.insert("schema_version", static_cast<quint32>(r.schema_version()));
    m.insert("content_hash",
             QByteArray(r.content_hash().data(),
                        static_cast<int>(r.content_hash().size())).toHex());
    m.insert("timestamp", static_cast<qulonglong>(r.timestamp()));
    m.insert("geohash", QString::fromStdString(r.geohash()));
    return m;
}

QVariantMap errorMap(const QString& msg) {
    QVariantMap m;
    m.insert("ok", false);
    m.insert("error", msg);
    return m;
}

}  // namespace

LogosWitnessCorePlugin::LogosWitnessCorePlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "LogosWitnessCorePlugin: Constructor";
}

LogosWitnessCorePlugin::~LogosWitnessCorePlugin() = default;

void LogosWitnessCorePlugin::initLogos(LogosAPI* logosAPIInstance) {
    if (logos) { delete logos; logos = nullptr; }
    if (logosAPI) { delete logosAPI; logosAPI = nullptr; }
    logosAPI = logosAPIInstance;
    if (logosAPI) { logos = new LogosModules(logosAPI); }
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

    // STUB: hashing the unstripped bytes. Phase 4 replaces with
    // exif_strip(content) → hash(stripped). Storage upload is Phase 5.
    const QByteArray hash = QCryptographicHash::hash(content, QCryptographicHash::Sha256);

    logos::witness::v1::Reference ref;
    ref.set_schema_version(kSchemaVersion);
    ref.set_content_hash(std::string(hash.constData(), static_cast<size_t>(hash.size())));
    ref.set_timestamp(static_cast<std::uint64_t>(ts));
    ref.set_geohash(geohash.toStdString());

    std::string buf;
    if (!ref.SerializeToString(&buf)) return errorMap("protobuf serialize failed");
    const QByteArray refBytes(buf.data(), static_cast<int>(buf.size()));
    store_.append(refBytes);

    emit referenceObserved(refBytes);

    QVariantMap r;
    r.insert("ok", true);
    r.insert("content_hash", hash.toHex());
    return r;
}

QVariantList LogosWitnessCorePlugin::listInscriptions(const QVariantMap& filter) {
    Q_UNUSED(filter);  // Stub ignores filter; v1 will honour bbox + time-range.
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
    // Stub: Delivery subscribe wired in Phase 6. Today, referenceObserved
    // signals fire from local submitPhoto only.
}
