#ifndef LOGOS_WITNESS_CORE_INTERFACE_H
#define LOGOS_WITNESS_CORE_INTERFACE_H

#include <QObject>
#include "interface.h"

class LogosWitnessCoreInterface : public PluginInterface
{
public:
    virtual ~LogosWitnessCoreInterface() = default;
};

#define LogosWitnessCoreInterface_iid "org.logos.LogosWitnessCoreInterface"
Q_DECLARE_INTERFACE(LogosWitnessCoreInterface, LogosWitnessCoreInterface_iid)

#endif
