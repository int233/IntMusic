#include "settingconfig.h"

SettingConfig::SettingConfig(QWidget *parent)
    : QWidget{parent}
{
    // 初始化 QSettings
    ConfigManager& configManager = ConfigManager::instance();
    intSetting = configManager.getSettings();

    // 创建布局
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(10, 10, 10, 10);

    // 创建 QTextEdit 用于显示配置内容
    QTextEdit *configDisplay = new QTextEdit(this);
    configDisplay->setReadOnly(true); // 设置为只读
    layout->addWidget(configDisplay);

    // 显示配置内容
    updateConfigDisplay(configDisplay);

    // 监听配置文件变化: updateConfigDisplay(configDisplay)
    connect(&configManager, &ConfigManager::settingsChanged, this, [this, configDisplay]() {
        updateConfigDisplay(configDisplay); // 更新显示
    });

}

void SettingConfig::updateConfigDisplay(QTextEdit *configDisplay) {
    // 清空显示
    configDisplay->clear();

    // 获取所有配置项的键
    if (!intSetting){
        qWarning() << "intSetting is nullptr!";
    }

    QStringList keys = intSetting->allKeys();

    // 遍历所有键值对并显示
    for (const QString &key : keys) {
        QVariant value = intSetting->value(key);
        QString line = QString("%1: %2").arg(key).arg(value.toString());
        configDisplay->append(line);
    }

}
