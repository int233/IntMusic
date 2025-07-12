#include "setting.h"

TabSetting::TabSetting(QWidget *parent)
    : QWidget{parent}
{
    // Main Setting Layout
    QHBoxLayout *mainLayout = new QHBoxLayout(this);

    // Tab Layout
    QTabWidget *tabWidget = new QTabWidget(this);

    //Common Tab
    SettingCommon *tabSettingTabCommon = new SettingCommon(this);
    tabWidget->addTab(tabSettingTabCommon, "通用");

    // Config
    SettingConfig *tabSettingTabConfig = new SettingConfig(this);
    tabWidget->addTab(tabSettingTabConfig, "Config");

    mainLayout->addWidget(tabWidget);

}
