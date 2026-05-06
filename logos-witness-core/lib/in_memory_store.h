#ifndef LOGOS_WITNESS_IN_MEMORY_STORE_H
#define LOGOS_WITNESS_IN_MEMORY_STORE_H

#include <QByteArray>
#include <QMutex>
#include <QVector>

// Process-local stand-in for Storage + Delivery + chain. Holds canonical
// serialised Reference bytes in insertion order. Replaced phase-by-phase
// by real backends without touching the LogosWitnessCoreInterface surface.
class InMemoryStore {
public:
    void append(const QByteArray& refBytes);
    QVector<QByteArray> snapshot() const;
    int size() const;

private:
    mutable QMutex mu_;
    QVector<QByteArray> refs_;
};

#endif
