#include "logos_witness_core_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include <QDebug>

LogosWitnessCorePlugin::LogosWitnessCorePlugin(QObject* parent)
    : QObject(parent)
{
    qDebug() << "LogosWitnessCorePlugin: Constructor called";
}

LogosWitnessCorePlugin::~LogosWitnessCorePlugin()
{
    qDebug() << "LogosWitnessCorePlugin: Destructor called";
}

void LogosWitnessCorePlugin::initLogos(LogosAPI* logosAPIInstance) {
    if (logos) {
        delete logos;
        logos = nullptr;
    }
    if (logosAPI) {
        delete logosAPI;
        logosAPI = nullptr;
    }
    logosAPI = logosAPIInstance;
    if (logosAPI) {
        logos = new LogosModules(logosAPI);
    }
}
