#ifndef LOGOS_WITNESS_CORE_INTERFACE_H
#define LOGOS_WITNESS_CORE_INTERFACE_H

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include "interface.h"

// Public surface of the Logos Witness core module. Contract is locked at
// SPEC §1.3; the implementation behind it is replaced phase-by-phase
// (in-memory stub today, then strip → Storage → Delivery → zone-sdk).
//
// All Q_INVOKABLE methods MUST return QVariantMap-shaped results of the
// form `{"ok": bool, "error": str?, ...}` — no exceptions cross the
// invokable boundary.
class LogosWitnessCoreInterface : public PluginInterface
{
public:
    virtual ~LogosWitnessCoreInterface() = default;

// Pick a photo, anchor it to a user-confirmed (timestamp, geohash),
    // strip metadata, hand the bytes to Storage, build a Reference,
    // announce it on Delivery, queue it for the next on-chain batch.
    // Returns: {ok, error?, content_hash, storage_cid?}.
    // `timestamp` is a decimal-string of unix seconds. Stringly-typed on
    // purpose: Qt's logosAPI marshalling and the logoscore CLI both
    // hand numeric args off as QString, so accepting qint64 here would
    // silently fail with "method not invokable".
    Q_INVOKABLE virtual QVariantMap submitPhoto(const QString& filePath,
                                                  const QString& timestamp,
                                                  const QString& geohash) = 0;

    // Fetch a photo from Logos Storage by CID. Returns the photo as a
    // data URL (data:image/jpeg;base64,...) that the UI can set as
    // Image.source without hitting basecamp's sandboxed QNetworkAccessManager.
    // Returns: {ok, error?, data_url?}.
    // Internally downloads from storage_module, caches in-process, and
    // base64-encodes the result so the sandboxed QML engine can render it.
    Q_INVOKABLE virtual QVariantMap fetchPhoto(const QString& cid) = 0;

    // Snapshot of all known references — live (Delivery) + historical
    // (chain scan) — merged and deduplicated by content_hash. The
    // `filter` argument is reserved for v1 (bbox / time-range). The
    // zero-arg overload is for CLI/JS callers that cannot easily
    // construct a QVariantMap on the wire.
    Q_INVOKABLE virtual QVariantList listInscriptions(const QVariantMap& filter) = 0;
    Q_INVOKABLE virtual QVariantList listInscriptions() = 0;

    // Drain the pending-inscription queue and commit one ReferenceBatch
    // on-chain via zone-sdk. Manual trigger only in v0 (SPEC §2). Stub
    // returns {ok: true, flushed: 0} until Phase 7.
    Q_INVOKABLE virtual QVariantMap flushBatch() = 0;

    // Idempotent opt-in to the live Delivery feed. Signals fire after.
    Q_INVOKABLE virtual void subscribeFeed() = 0;

    // Wire-format decoders. Pure functions; no store access. Exist so the
    // pure-QML UI module can consume `referenceObserved` payloads and place
    // map markers from geohash-only Refs without re-deriving the wire
    // format. See SPEC §2 Core module surface.
    // decodeReference returns the same `{schema_version, content_hash,
    // timestamp, geohash}` shape that listInscriptions entries use, plus
    // {ok, error?}.
    Q_INVOKABLE virtual QVariantMap decodeReference(const QByteArray& refBytes) = 0;
    // decodeGeohash returns `{ok, error?, latitude, longitude}` of the
    // geohash centroid. Precision is whatever the input carries.
    Q_INVOKABLE virtual QVariantMap decodeGeohash(const QString& geohash) = 0;
};

#define LogosWitnessCoreInterface_iid "org.logos.LogosWitnessCoreInterface"
Q_DECLARE_INTERFACE(LogosWitnessCoreInterface, LogosWitnessCoreInterface_iid)

#endif
