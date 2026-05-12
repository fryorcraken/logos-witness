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
#include "../lib/in_memory_store.h"

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

    Q_INVOKABLE void initLogos(LogosAPI* logosAPIInstance);

signals:
    void referenceObserved(const QByteArray& refBytes);
    void inscriptionsLoaded(const QVariantList& refs);

private:
    LogosModules* logos = nullptr;
    InMemoryStore store_;
};

#endif
