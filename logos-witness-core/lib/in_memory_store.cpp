#include "in_memory_store.h"

void InMemoryStore::append(const QByteArray& refBytes) {
    QMutexLocker lock(&mu_);
    refs_.append(refBytes);
}

QVector<QByteArray> InMemoryStore::snapshot() const {
    QMutexLocker lock(&mu_);
    return refs_;
}

int InMemoryStore::size() const {
    QMutexLocker lock(&mu_);
    return refs_.size();
}
