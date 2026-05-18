#ifndef LOGOS_WITNESS_UI_QML_PLUGIN_H
#define LOGOS_WITNESS_UI_QML_PLUGIN_H

#include <QString>
#include "logos_witness_ui_qml_interface.h"
#include "LogosViewPluginBase.h"
#include "rep_logos_witness_ui_qml_source.h"

class LogosAPI;
class LogosModules;

// Minimal hybrid-mode backend stub. The UI module currently routes all
// functional calls through `logos.callModule("logos_witness_core", ...)`
// from QML — this plugin exists only to prove the hybrid toolchain (C++
// backend + QML view) loads end-to-end. No business logic lives here yet.
class LogosWitnessUiQmlPlugin : public LogosWitnessUiQmlSimpleSource,
                                public LogosWitnessUiQmlInterface,
                                public LogosWitnessUiQmlViewPluginBase
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID LogosWitnessUiQmlInterface_iid FILE "metadata.json")
    Q_INTERFACES(LogosWitnessUiQmlInterface)

public:
    explicit LogosWitnessUiQmlPlugin(QObject* parent = nullptr);
    ~LogosWitnessUiQmlPlugin() override;

    QString name()    const override { return "logos_witness_ui_qml"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

private:
    LogosAPI* m_logosAPI = nullptr;
    LogosModules* m_logos = nullptr;
};

#endif // LOGOS_WITNESS_UI_QML_PLUGIN_H
