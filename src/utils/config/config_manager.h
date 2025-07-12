#ifndef CONFIGMANAGER_H
#define CONFIGMANAGER_H

#include <QObject>
#include <QString>
#include <QDir>
#include <QMutex>
#include <QStandardPaths>
#include <QSettings>
#include <QDirIterator>

#include "models/library_info.h"

class ConfigManager : public QObject
{
    Q_OBJECT
public:
    explicit ConfigManager(const QString& config_path, QObject *parent = nullptr);
    ~ConfigManager();
    QVariant get(const QString &key, const QVariant &defaultValue = QVariant());
    void set(const QString &key, const QVariant &value);

    // config
    QSettings* get_settings() const;
    QList<LibraryInfo> get_library_infos() const;
    QString get_config_path() const;
    void migrate_config(const QString &new_config_path);

    const QString kConfigFileName = "intmusic.ini";

    QString FindOrCreateConfigPath() const;
    QString get_home_path() const;
    QString get_music_folder_path() const;
    QString get_music_folder_config_path() const;
    QString get_home_config_path() const;

    // library
    bool CheckLibraryExists(const QString &library_id); 
    void add_library(const QString &library_id, const QString &name, const QString &path);
    void remove_library(const QString &library_id);
    void set_default_library(const QString &library_id);

    // migration
    bool CopyDirectory(const QDir &sourceDir, const QDir &targetDir, bool removeSourceAfterCopy = false);


private:
    QMutex m_mutex;
    QSettings* m_settings = nullptr;

signals:
    void settingsChanged();

};

#endif // CONFIGMANAGER_H
