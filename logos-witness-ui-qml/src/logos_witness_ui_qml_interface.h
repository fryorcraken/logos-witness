#ifndef LOGOS_WITNESS_UI_QML_INTERFACE_H
#define LOGOS_WITNESS_UI_QML_INTERFACE_H

#include <QObject>
#include <QString>
#include "interface.h"

class LogosWitnessUiQmlInterface : public PluginInterface
{
public:
    virtual ~LogosWitnessUiQmlInterface() = default;
};

#define LogosWitnessUiQmlInterface_iid "org.logos.LogosWitnessUiQmlInterface"
Q_DECLARE_INTERFACE(LogosWitnessUiQmlInterface, LogosWitnessUiQmlInterface_iid)

#endif // LOGOS_WITNESS_UI_QML_INTERFACE_H
