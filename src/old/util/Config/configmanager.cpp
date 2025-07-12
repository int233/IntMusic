#include "configmanager.h"

ConfigManager& ConfigManager::instance() {
    static ConfigManager instance;
    return instance;
}

ConfigManager::ConfigManager(QObject *parent)
    : QObject{parent}
{
    QString currentTime = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss");

    QString path = GetConfigPath();

    m_settings = new QSettings(path, QSettings::IniFormat, this);

    SaveConfig(path, m_settings);

    emit settingsChanged();
}

QString ConfigManager::configPath() const {
    // return m_settings ? m_settings->fileName() : QString();
    return m_settings->value("Common/ConfigPath").toString();
}

QSettings* ConfigManager::getSettings() {

    return m_settings;

}

QStringList ConfigManager::musicDatabasePaths() {
    QString libraryFolderPath = m_settings->value("Common/LibraryPath/").toString();

    const QString librarySubfix = "intlibrary";
    QStringList filePaths;

    // 检查目录是否存在
    QDir libraryDir(libraryFolderPath);
    if (!libraryDir.exists()) {
        qWarning() << "Library directory does not exist:" << libraryFolderPath;
        return filePaths; // 返回空列表
    }

    // 使用 QDirIterator 遍历目录
    QDirIterator it(libraryFolderPath, QStringList() << "*." + librarySubfix, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        filePaths.append(it.next());
    }

    return filePaths;

}

QString ConfigManager::GetConfigPath(){

    // 检查用户目录下的IntMusic/config.ini
    QString userConfigPath = GetHomeConfigPath();
    if (QFileInfo::exists(userConfigPath)) {
        return userConfigPath;
    }

    // 检查音乐目录下的IntMusic/config.ini
    QString musicConfigPath = GetMusicFolderConfigPath();
    if (QFileInfo::exists(musicConfigPath)) {
        return musicConfigPath;
    }

    // 两个路径都不存在则在GetHomeConfigPath()创建新的配置文件
    QString newConfigPath = GetHomeConfigPath();
    QDir configDir = QFileInfo(newConfigPath).dir();
    if (!configDir.exists()) {
        if (!configDir.mkpath(".")) {
            qWarning() << "Failed to create config directory:" << configDir.path();
            return QString();
        }
    }

    QSettings newConfig(newConfigPath, QSettings::IniFormat);
    // 设置默认值
    newConfig.setValue("Common/Title", "IntMusic Player");
    newConfig.setValue("Common/ConfigPath", GetHomePath());
    newConfig.sync(); // 确保文件被写入磁盘

    if (newConfig.status() != QSettings::NoError) {
        qWarning() << "Failed to create config file:" << newConfigPath;
        return QString(); // 返回空字符串表示失败
    }

    qDebug() << "Created new config file at:" << newConfigPath;

    return newConfigPath;
}

QString ConfigManager::GetHomePath(){
    QDir userDir(QDir::home());
    return userDir.filePath("IntMusic/");
}

QString ConfigManager::GetMusicFolderPath(){
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    return QDir(musicBaseDir).filePath("/");
}

QString ConfigManager::GetHomeConfigPath(){
    QDir userDir(QDir::home());
    QString userConfigPath = userDir.filePath("IntMusic/" + configFileName);
    return userConfigPath;
}

QString ConfigManager::GetMusicFolderConfigPath(){
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    QString musicConfigPath = QDir(musicBaseDir).filePath("IntMusic/" + configFileName);
    return musicConfigPath;
}

QString ConfigManager::GetHomeLibraryPath(){
    QDir userDir(QDir::home());
    QString userConfigPath = userDir.filePath("IntMusic/library/");
    QDir dir;
    if (!dir.mkpath(userConfigPath)) {
        qWarning() << "Failed to create directory:" << userConfigPath;
    } else {
        qDebug() << "Directory created successfully:" << userConfigPath;
    }
    return userConfigPath;
}
QString ConfigManager::GetMusicFolderLibraryPath(){
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    QString musicConfigPath = QDir(musicBaseDir).filePath("IntMusic/library/");
    QDir dir;
    if (!dir.mkpath(musicConfigPath)) {
        qWarning() << "Failed to create directory:" << musicConfigPath;
    } else {
        qDebug() << "Directory created successfully:" << musicConfigPath;
    }
    return musicConfigPath;
}

QString ConfigManager::SaveConfig(QString configPath, QSettings* externalSettings) {

    if (configPath.isEmpty()) {
        configPath = GetHomeConfigPath();
    }

    // 创建/打开配置文件
    QSettings targetSettings(configPath, QSettings::IniFormat);


    // 如果传入了外部配置，复制其内容
    if (externalSettings) {
        // 确保读取到最新内容
        externalSettings->sync();

        // 复制所有键值对
        foreach (const QString &key, externalSettings->allKeys()) {
            targetSettings.setValue(key, externalSettings->value(key));
        }
    }

    // 强制写入磁盘
    targetSettings.sync();
    return configPath;
}

int ConfigManager::setConfig(QString key, QVariant value) {

    if (!m_settings) {
        qWarning() << "m_settings is null!";
        return -1; // 返回错误码
    }

    // 检查 key 是否存在
    if (m_settings->contains(key)) {
        QVariant oldValue = m_settings->value(key);
        qDebug() << "Key" << key << "exists. Old value:" << oldValue << "New value:" << value;
    } else {
        qDebug() << "Key" << key << "does not exist. Setting new value:" << value;
    }

    // 设置新的值
    m_settings->setValue(key, value);
    m_settings->sync(); // 强制写入磁盘

    // 发射配置变化信号
    emit settingsChanged();

    return 1;
}

    // 迁移配置文件
void ConfigManager::migrateConfig(QString oldFolder, QString newFolder){
    QDir oldDir(oldFolder);
    QDir newDir(newFolder);

    QString canonicalOldPath = oldDir.canonicalPath();
    QString canonicalNewPath = newDir.canonicalPath();

    if (canonicalOldPath == canonicalNewPath) {
        qDebug() << "Source and destination paths are the same. No migration needed.";
        return;
    }

    if (!newDir.exists()) {
        if (!newDir.mkpath(".")) {
            qWarning() << "Failed to create destination directory:" << newFolder;
            return;
        }
    }

    if (copyDirectory(oldDir, newDir, true)) {
        qDebug() << "Successfully migrated IntMusic folder from" << oldFolder << "to" << newFolder;

        // 更新 QSettings 的路径
        QString newIniPath = newDir.filePath("IntMusic.ini");
        if (m_settings) {
            delete m_settings; // 删除旧的 QSettings 对象
        }
        m_settings = new QSettings(newIniPath, QSettings::IniFormat, this);
    } else {
        qWarning() << "Failed to migrate IntMusic folder from" << oldFolder << "to" << newFolder;
    }
}

bool ConfigManager::copyDirectory(const QDir &sourceDir, const QDir &targetDir, bool removeSourceAfterCopy = false) {
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
            if (!copyDirectory(QDir(sourcePath), targetSubDir, removeSourceAfterCopy)) {
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