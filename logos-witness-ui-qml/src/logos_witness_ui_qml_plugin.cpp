#include "logos_witness_ui_qml_plugin.h"
#include "logos_api.h"
#include "logos_sdk.h"

#include <QDebug>

LogosWitnessUiQmlPlugin::LogosWitnessUiQmlPlugin(QObject* parent)
    : LogosWitnessUiQmlSimpleSource(parent)
{
}

LogosWitnessUiQmlPlugin::~LogosWitnessUiQmlPlugin()
{
    delete m_logos;
}

void LogosWitnessUiQmlPlugin::initLogos(LogosAPI* api)
{
    if (m_logos) return;
    m_logosAPI = api;
    m_logos = new LogosModules(api);
    setBackend(this);
    setBackendStatus(QStringLiteral("ready"));
    qInfo() << "logos_witness_ui_qml: hybrid backend initialised";
}
