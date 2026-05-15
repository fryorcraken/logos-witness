#ifndef LOGOS_WITNESS_DELIVERY_CLIENT_H
#define LOGOS_WITNESS_DELIVERY_CLIENT_H

#include <QByteArray>
#include <QObject>
#include <QString>

struct LogosModules;

// Thin wrapper around the typed delivery_module accessor. Owns the
// createNode/start lifecycle and one subscription to the v0 witness
// topic; exposes publish() for protobuf-serialized References and emits
// referenceReceived(refBytes) for inbound messages from peers. The
// upstream module's send() base64-encodes whatever QString it receives
// (treating it as UTF-8), so binary protobuf bytes have to be base64-
// encoded by us before send(). The receive event then carries
// base64(our_base64(refBytes)); we double-decode in onMessage().
class DeliveryClient : public QObject {
    Q_OBJECT
public:
    explicit DeliveryClient(LogosModules* logos, QObject* parent = nullptr);
    ~DeliveryClient() override;

    bool init(const QString& topic);
    bool isReady() const { return started_; }

    // Publishes a serialized Reference on the topic the client was
    // initialised against. Returns true if the underlying send call
    // accepted the message (it returns a request id synchronously);
    // propagation is fire-and-forget at v0.
    bool publish(const QByteArray& refBytes);

signals:
    void deliveryReady();
    // Carries the protobuf bytes of a Reference received from a peer.
    // The plugin slot deserialises, dedupes by content_hash, and (if
    // new) appends to the store + emits its own referenceObserved.
    void referenceReceived(const QByteArray& refBytes);

private:
    void onMessageReceivedRaw(const QVariantList& data);

    LogosModules* logos_ = nullptr;
    QString topic_;
    bool started_ = false;
};

#endif
