#ifndef LOGOS_WITNESS_STORAGE_CLIENT_H
#define LOGOS_WITNESS_STORAGE_CLIENT_H

#include <QByteArray>
#include <QObject>
#include <QString>

struct LogosModules;

class StorageClient : public QObject {
    Q_OBJECT
public:
    explicit StorageClient(LogosModules* logos, QObject* parent = nullptr);
    ~StorageClient() override;

    bool init(const QString& configJson);
    bool start();
    void stop();
    void destroy();
    bool isReady() const { return started_; }

    struct UploadResult { bool ok = false; QString cid; QString error; };
    UploadResult upload(const QByteArray& data, const QString& cacheDir);

    struct DownloadResult { bool ok = false; QByteArray data; QString error; };
    DownloadResult download(const QString& cid, const QString& cacheDir);

    bool exists(const QString& cid);

signals:
    void storageReady();

private:
    LogosModules* logos_ = nullptr;
    bool started_ = false;
};

#endif
