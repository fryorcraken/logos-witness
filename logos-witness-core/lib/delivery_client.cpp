#include "delivery_client.h"
#include "logos_sdk.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>

DeliveryClient::DeliveryClient(LogosModules* logos, QObject* parent)
    : QObject(parent), logos_(logos)
{
}

DeliveryClient::~DeliveryClient()
{
    if (started_ && logos_) {
        logos_->delivery_module.stop();
    }
}

bool DeliveryClient::init(const QString& topic)
{
    if (!logos_) return false;

    topic_ = topic;

    // portsShift picks a random offset to keep two profiles on the same
    // box (alice + bob) from colliding on the underlying tcp/rest/
    // discv5/websocket ports. The upstream module bakes the offset into
    // every internal port; the demo project does the same. Replace with
    // an explicit LOGOS_DELIVERY_PORTS_SHIFT env var so the launcher
    // script can pin a deterministic offset per profile if needed
    // (alice → 0, bob → 100, etc.).
    int portsShift = qEnvironmentVariableIntValue("LOGOS_DELIVERY_PORTS_SHIFT");
    if (portsShift <= 0) {
        portsShift = 100 + static_cast<int>(QRandomGenerator::global()->bounded(4500));
    }

    QJsonObject cfg{
        {"logLevel",   "INFO"},
        {"mode",       "Core"},
        {"preset",     "logos.dev"},
        {"portsShift", portsShift}
    };
    const QString cfgJson = QString::fromUtf8(
        QJsonDocument(cfg).toJson(QJsonDocument::Compact));

    qInfo() << "DeliveryClient: createNode portsShift=" << portsShift;
    LogosResult create = logos_->delivery_module.createNode(cfgJson);
    if (!create.success) {
        qWarning() << "DeliveryClient: createNode failed:" << create.error.toString();
        return false;
    }

    LogosResult started = logos_->delivery_module.start();
    if (!started.success) {
        qWarning() << "DeliveryClient: start failed:" << started.error.toString();
        return false;
    }

    // Register messageReceived handler before subscribe so we don't drop
    // any inbound that arrives between start and the on() call. The cb
    // shape is EventCallback(QVariantList) — the typed accessor strips
    // the eventName for us.
    logos_->delivery_module.on("messageReceived",
        [this](const QVariantList& data) { onMessageReceivedRaw(data); });

    LogosResult sub = logos_->delivery_module.subscribe(topic_);
    if (!sub.success) {
        qWarning() << "DeliveryClient: subscribe failed:" << sub.error.toString();
        return false;
    }

    started_ = true;
    qInfo() << "DeliveryClient: ready; topic=" << topic_;
    emit deliveryReady();
    return true;
}

bool DeliveryClient::publish(const QByteArray& refBytes)
{
    if (!started_ || !logos_) return false;

    // delivery_module.send()'s `payload` argument is documented as taking
    // a base64-encoded string. We pre-encode our protobuf bytes here;
    // the receive event surfaces the same single-base64 string back
    // (NOT doubly-encoded — see the `onMessageReceivedRaw` comment).
    const QString b64 = QString::fromLatin1(refBytes.toBase64());
    LogosResult r = logos_->delivery_module.send(topic_, b64);
    if (!r.success) {
        qWarning() << "DeliveryClient: send failed:" << r.error.toString();
        return false;
    }
    return true;
}

void DeliveryClient::onMessageReceivedRaw(const QVariantList& data)
{
    // Event contract (delivery_module_plugin.h:37):
    //   data[0] message hash, data[1] content topic, data[2] payload
    //   (base64), data[3] timestamp ns.
    if (data.size() < 3) {
        qWarning() << "DeliveryClient: messageReceived has only"
                   << data.size() << "fields";
        return;
    }
    const QString recvTopic = data[1].toString();
    if (recvTopic != topic_) {
        // Defensive — only subscribed to one topic in v0, but the bridge
        // could plausibly fan messages from multiple subs to one cb.
        qCritical() << "DeliveryClient: topic mismatch, dropping";
        return;
    }

    // Single-decode: delivery_module surfaces `data[2]` as the same
    // base64 string we passed to `send()` — NOT doubly-encoded. An
    // earlier version of this code did `fromBase64(fromBase64(data[2]))`
    // on the assumption (from a misread of the demo project) that the
    // module wrapped our payload a second time on the way out. The
    // double-decode silently truncated to half-size garbage that
    // protobuf failed to parse; cross-instance refs arrived on the
    // wire but were dropped here. Dogfood traced 2026-05-18 confirms
    // single-decode is right.
    const QByteArray refBytes = QByteArray::fromBase64(
        data[2].toString().toLatin1());
    if (refBytes.isEmpty()) {
        qWarning() << "DeliveryClient: empty payload after decode";
        return;
    }
    emit referenceReceived(refBytes);
}
