#include "config_loader.h"
#include <QDir>
#include <QStandardPaths>
#include <QSettings>
#include <QDebug>
#include <QFileInfo>

QString ConfigLoader::FindOrCreateConfigPath() {

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

QString ConfigLoader::get_home_path() {
    return QDir::home().filePath("IntMusic/");
}

QString ConfigLoader::get_music_folder_path(){
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    return QDir(musicBaseDir).filePath("/");
}

QString ConfigLoader::get_home_config_path(){
    QDir userDir(QDir::home());
    QString userConfigPath = userDir.filePath("IntMusic/" + kConfigFileName);
    return userConfigPath;
}

QString ConfigLoader::get_music_folder_config_path(){
    QString musicBaseDir = QStandardPaths::writableLocation(QStandardPaths::MusicLocation);
    QString musicConfigPath = QDir(musicBaseDir).filePath("IntMusic/" + kConfigFileName);
    return musicConfigPath;
}
