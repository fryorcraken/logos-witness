#ifndef LOGOS_WITNESS_CORE_PLUGIN_H
#define LOGOS_WITNESS_CORE_PLUGIN_H

#include <QObject>
#include <QString>
#include "logos_witness_core_interface.h"
#include "logos_api.h"
#include "logos_sdk.h"

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

    Q_INVOKABLE void initLogos(LogosAPI* logosAPIInstance);

private:
    LogosModules* logos = nullptr;
};

#endif
