#ifndef CONFIGLOADER_H
#define CONFIGLOADER_H

#include <QString>

namespace ConfigLoader {
    const QString kConfigFileName = "intmusic.ini";

    QString FindOrCreateConfigPath();

    // 各种路径获取工具函数
    QString get_home_path();
    QString get_music_folder_path();
    QString get_music_folder_config_path();
    QString get_home_config_path();

}

#endif // CONFIGLOADER_H