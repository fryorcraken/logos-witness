#ifndef LOGOS_WITNESS_CORE_PLUGIN_H
#define LOGOS_WITNESS_CORE_PLUGIN_H

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include "logos_witness_core_interface.h"
#include "logos_api.h"
#include "logos_sdk.h"
#include "../lib/delivery_client.h"
#include "../lib/in_memory_store.h"
#include "../lib/storage_client.h"

#include <QSet>

class LogosWitnessCorePlugin : public QObject, public LogosWitnessCoreInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID LogosWitnessCoreInterface_iid FILE "metadata.json")
    Q_INTERFACES(LogosWitnessCoreInterface PluginInterface)

public:
    explicit LogosWitnessCorePlugin(QObject* parent = nullptr);
    ~LogosWitnessCorePlugin() override;

    QString name() const override { return "logos_witness_core"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE QVariantMap submitPhoto(const QString& filePath,
                                         const QString& timestamp,
                                         const QString& geohash) override;
    Q_INVOKABLE QVariantList listInscriptions(const QVariantMap& filter) override;
    Q_INVOKABLE QVariantList listInscriptions() override;
    Q_INVOKABLE QVariantMap flushBatch() override;
    Q_INVOKABLE void subscribeFeed() override;
    Q_INVOKABLE QVariantMap decodeReference(const QByteArray& refBytes) override;
    Q_INVOKABLE QVariantMap decodeGeohash(const QString& geohash) override;
    Q_INVOKABLE QVariantMap fetchPhoto(const QString& cid) override;

    Q_INVOKABLE void initLogos(LogosAPI* logosAPIInstance);

    // Liveness probes for the UI's status badges. Return the current
    // values of `deliveryReady_` / `storageReady_`; not part of the
    // locked interface (UI-only convenience). The UI shows them as
    // two separate pills because they fail independently: delivery
    // covers cross-instance ref broadcast (waku/libp2p), storage
    // covers photo upload + fetch (storage_module + DHT).
    Q_INVOKABLE bool deliveryReady() const { return deliveryReady_; }
    Q_INVOKABLE bool storageReady()  const { return storageReady_; }

signals:
    void referenceObserved(const QByteArray& refBytes);
    void inscriptionsLoaded(const QVariantList& refs);

private slots:
    void _onDeliveryReceived(const QByteArray& refBytes);

private:
    QString cacheDir() const;
    bool _ensureStorage();
    bool _ensureDelivery();

    LogosModules* logos = nullptr;
    InMemoryStore store_;
    StorageClient* storage_ = nullptr;
    bool storageReady_ = false;
    DeliveryClient* delivery_ = nullptr;
    bool deliveryReady_ = false;
    // Dedupe key: content_hash of every Reference we've already seen
    // (local submit + inbound from Delivery). Same hash from both
    // sources collapses to one timeline entry. v0: no eviction; the
    // set grows linearly with unique refs, fine for the demo scale.
    QSet<QByteArray> knownHashes_;
};

#endif
