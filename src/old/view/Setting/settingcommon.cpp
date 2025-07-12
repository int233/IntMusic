#include "settingcommon.h"

SettingCommon::SettingCommon(QWidget *parent)
    : QWidget{parent},configManager(ConfigManager::instance()),musicScanner(MusicScanner::instance())
{

    QVBoxLayout *commonLayout = new QVBoxLayout(this);

    commonLayout->setContentsMargins(10, 10, 10, 10);
    commonLayout->setSpacing(10);

    // 配置文件存储路径
    CardCombo *configStoragePathCard = new CardCombo("数据存储路径","选择数据存储的位置", this);
    QStringList configPathOptions;
    configPathOptions << "用户数据路径" << "音乐目录";
    configStoragePathCard->setOptions(configPathOptions);
    QString currentConfigPath = configManager.getSettings()->value("Common/ConfigPath").toString();
    if (currentConfigPath == configManager.GetHomePath()) {
        configStoragePathCard->setCurrentIndex(0); // 选中"用户数据路径"
    } else if (currentConfigPath == configManager.GetMusicFolderPath()) {
        configStoragePathCard->setCurrentIndex(1); // 选中"音乐目录"
    } else {
        configStoragePathCard->setCurrentIndex(1);
        
    }

    // Music Scanner

    MusicScanView *musicScanView = new MusicScanView(this);

    // Test Path Select
    CardPathSelect *PathSelect = new CardPathSelect("音乐文件夹", "选择音乐文件夹路径", this);


    // 将 ComboCard 添加到布局
    commonLayout->addWidget(configStoragePathCard);
    commonLayout->addWidget(musicScanView);
    commonLayout->addWidget(PathSelect);
    commonLayout->addStretch();

    connect(configStoragePathCard->getComboBox(),
            QOverload<int>::of(&QComboBox::currentIndexChanged),
            this,
            &SettingCommon::ConfigStoragePathChanged
    );
    
}


void SettingCommon::ConfigStoragePathChanged(int index){
    QString oldpath = configManager.configPath();
    QString path;
    switch (index) {
    case 0: // "用户数据路径"
        path = configManager.GetHomePath();
        break;
    case 1: // "音乐目录"
        path = configManager.GetMusicFolderPath();
        break;
    default:
        qWarning() << "Invalid index:" << index;
        return;
    }
    configManager.setConfig("Common/ConfigPath", path);
    qDebug() << "Config path from " <<  oldpath  << " changed to:" << path;
    configManager.migrateConfig(oldpath, path);
}


