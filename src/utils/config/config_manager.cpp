#include "config_manager.h"
#include "config_loader.h"
#include <QDir>
#include <QDirIterator>
#include <QMutexLocker>


ConfigManager::ConfigManager(const QString& config_path, QObject *parent)
    : QObject{parent}
{
    m_settings = new QSettings(config_path, QSettings::IniFormat, this);
    if (m_settings->status() != QSettings::NoError) {
        qWarning() << "Failed to load settings file:" << config_path;
    }
}

ConfigManager::~ConfigManager() {
}

QVariant ConfigManager::get(const QString& key, const QVariant& defaultValue) {
    QMutexLocker locker(&m_mutex);
    return m_settings->value(key, defaultValue);
}

void ConfigManager::set(const QString& key, const QVariant& value) {
    {
        QMutexLocker locker(&m_mutex);
        m_settings->setValue(key, value);
        m_settings->sync();
    }
    emit settingsChanged();
}

QSettings* ConfigManager::get_settings() const {
    return m_settings;
}

QList<LibraryInfo> ConfigManager::get_library_infos() const {
    // 所有Common下以Library_开头的配置项，包含name和path
    QList<LibraryInfo> libraries;
    QStringList groups = m_settings->childGroups();
    
    for (const QString& group : groups) {
        // 检查是否是Library开头的分组
        if (group.startsWith("Library_")) {
            m_settings->beginGroup(group);
            
            // 检查必要字段是否存在
            if (m_settings->contains("id") && 
                m_settings->contains("name") && 
                m_settings->contains("path")) {
                
                LibraryInfo lib;
                lib.m_index = m_settings->value("index").toInt();     // 读取整数ID
                lib.m_id = group.mid(QString("Library_").length());   // 取Library_之后的内容
                lib.m_name = m_settings->value("name").toString();
                lib.m_path = m_settings->value("path").toString();
                
                libraries.append(lib);
            }
            m_settings->endGroup();
        }
    }
    return libraries;
}

QString ConfigManager::get_config_path() const {
    return m_settings->fileName();
}

void ConfigManager::migrate_config(const QString &new_config_path) {

    QMutexLocker locker(&m_mutex);

    QString oldConfigFile = m_settings->fileName();
    QString newConfigFile = new_config_path;

    QString oldDir = QFileInfo(oldConfigFile).absoluteDir().canonicalPath();
    QString newDir = QFileInfo(newConfigFile).absoluteDir().canonicalPath();

    if (oldDir.isEmpty()) {
        qCritical() << "oldDir empty: " << oldConfigFile;
        return;
    }

    // 如果新目录不存在，则创建它
    if (!QDir(newDir).exists()) {
        if (!QDir().mkpath(newDir)) {
            qWarning() << "Failed to create new config directory:" << newDir;
            return;
        }
    }

    qInfo() << "Old config directory:" << oldDir;
    qInfo() << "New config directory:" << newDir;

    if (oldDir == newDir) {
        qDebug() << "Source and destination paths are the same. No migration needed.";
        return;
    }

    if (CopyDirectory(oldDir, newDir, true)) {
        qDebug() << "Successfully migrated IntMusic folder from" << oldDir << "to" << newDir;

        // 更新 QSettings 的路径
        QString newIniPath = QDir(newDir).filePath("IntMusic.ini");
        if (m_settings) {
            delete m_settings; // 删除旧的 QSettings 对象
        }
        m_settings = new QSettings(newIniPath, QSettings::IniFormat, this);
    } else {
        qWarning() << "Failed to migrate IntMusic folder from" << oldDir << "to" << newDir;
    }
}

void ConfigManager::add_library(const QString &library_id, const QString &name, const QString &path) {
    QMutexLocker locker(&m_mutex);
    
    // 获取当前的库信息
    QList<LibraryInfo> libraries = get_library_infos();

    // 检查是否已存在同名库
    for (const LibraryInfo &lib : libraries) {
        if (lib.m_id == library_id) {
            qWarning() << "Library with ID" << library_id << "already exists.";
            return;
        }
    }

    // 递增创建新的index，并优先填补空缺
    qint8 newIndex = 0;
    for (const LibraryInfo &lib : libraries) {
        if (lib.m_index == newIndex) {
            newIndex++;
        } else if (lib.m_index > newIndex) {
            break;
        }
    }

    // 添加新的库信息
    m_settings->beginGroup(QString("Library_%1").arg(library_id));
    m_settings->setValue("index", newIndex);
    m_settings->setValue("id", library_id);
    m_settings->setValue("name", name);
    m_settings->setValue("path", path);
    m_settings->endGroup();
    m_settings->sync();
    qInfo() << "Added new library:" << library_id << "with path:" << path;

    emit settingsChanged();

    return;
}

bool ConfigManager::CheckLibraryExists(const QString &library_id) {
    bool existance = m_settings->childGroups().contains(QString("Library_%1").arg(library_id));
    if (existance) {
        qInfo() << "Library with ID" << library_id << "exists.";
    } else {
        qWarning() << "Library with ID" << library_id << "does not exist.";
    }
    return existance;
}

void ConfigManager::set_default_library(const QString &library_id) {
    QMutexLocker locker(&m_mutex);
    
    // 检查库是否存在
    if (!CheckLibraryExists(library_id)) {
        return;
    }

    // 设置默认库
    m_settings->setValue("Library/default", library_id);
    m_settings->sync();
    qInfo() << "Set default library to:" << library_id;

    emit settingsChanged();
    return;
}

void ConfigManager::remove_library(const QString &library_id) {
    QMutexLocker locker(&m_mutex);
    
    // 检查库是否存在
    if (!CheckLibraryExists(library_id)) {
        return;
    }

    // 删除库信息
    m_settings->remove(QString("Library_%1").arg(library_id));
    m_settings->sync();
    qInfo() << "Removed library with ID:" << library_id;

    emit settingsChanged();
}


bool ConfigManager::CopyDirectory(const QDir &sourceDir, const QDir &targetDir, bool removeSourceAfterCopy) {
    // 遍历源文件夹中的所有文件和子文件夹
    QFileInfoList entries = sourceDir.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot);

    for (const QFileInfo &entry : entries) {
        QString sourcePath = entry.absoluteFilePath();
        QString targetPath = targetDir.filePath(entry.fileName());

        if (entry.isDir()) {
            // 如果是子文件夹，递归复制
            QDir targetSubDir(targetPath);
            if (!targetSubDir.exists() && !targetSubDir.mkpath(".")) {
                qWarning() << "Failed to create subdirectory:" << targetPath;
                return false;
            }
            if (!CopyDirectory(QDir(sourcePath), targetSubDir, removeSourceAfterCopy)) {
                return false;
            }
        } else if (entry.isFile()) {
            // 如果是文件，直接复制
            if (!QFile::copy(sourcePath, targetPath)) {
                qWarning() << "Failed to copy file:" << sourcePath << "to" << targetPath;
                return false;
            }
        }
    }

    // 如果复制成功且需要删除源目录
    if (removeSourceAfterCopy) {
        QDir nonConstSourceDir(sourceDir.absolutePath());
        if (!nonConstSourceDir.removeRecursively()) {
            qWarning() << "Failed to remove source directory:" << sourceDir.absolutePath();
            return false;
        }
    }

    return true;
}

QString ConfigManager::FindOrCreateConfigPath() const {

    QString user_config_path = get_home_config_path();
    if (QFileInfo::exists(user_config_path)) {
        return user_config_path;
    }

    // 检查音乐目录下的IntMusic/config.ini
    QString music_config_path = get_music_folder_config_path();
    if (QFileInfo::exists(music_config_path)) {
        return music_config_path;
    }

    // // 两个路径都不存在则在GetHomeConfigPath()创建新的配置文件
    // QString newConfigPath = musicConfigPath;
    // QDir configDir = QFileInfo(newConfigPath).dir();
    // if (!configDir.exists()) {
    //     if (!configDir.mkpath(".")) {
    //         qWarning() << "Failed to create config directory:" << configDir.path();
    //         return QString(); // 返回空字符串表示失败
    //     }
    // }

    // QSettings newConfig(newConfigPath, QSettings::IniFormat);
    // // 设置默认值
    // newConfig.setValue("Common/Title", "IntMusic Player");
    // newConfig.setValue("Common/ConfigPath", get_home_path());
    // newConfig.sync(); // 确保文件被写入磁盘

    // if (newConfig.status() != QSettings::NoError) {
    //     qWarning() << "Failed to create config file:" << newConfigPath;
    //     return QString(); // 返回空字符串表示失败
    // }

    // qDebug() << "Created new config file at:" << newConfigPath;

    // return newConfigPath;

    qInfo() << "No existing config found. Creating new one...";

    QString new_config_path = music_config_path;

    QDir config_dir = QFileInfo(new_config_path).dir();
    if (!config_dir.exists()) {
        config_dir.mkpath(".");
    }

    QSettings newConfig(new_config_path, QSettings::IniFormat);
    newConfig.setValue("Common/Title", "IntMusic Player");
    newConfig.setValue("Common/default_library","main_collection"); // 设置默认值
    newConfig.sync();

    if (newConfig.status() != QSettings::NoError) {
        qWarning() << "Failed to create new config file:" << new_config_path;
        return QString();
    }
    
    return new_config_path;
}

QString ConfigManager::get_home_path() const {
    return QDir::home().filePath("IntMusic/");
}

QString ConfigManager::get_music_folder_path() const{
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    return QDir(musicBaseDir).filePath("/");
}

QString ConfigManager::get_home_config_path() const{
    QDir userDir(QDir::home());
    QString userConfigPath = userDir.filePath("IntMusic/" + kConfigFileName);
    return userConfigPath;
}

QString ConfigManager::get_music_folder_config_path() const{
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    QString musicConfigPath = QDir(musicBaseDir).filePath("IntMusic/" + kConfigFileName);
    return musicConfigPath;
}
