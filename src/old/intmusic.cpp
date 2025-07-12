#include "intmusic.h"

IntMusic::IntMusic(QWidget *parent): QMainWindow(parent)
{
    setWindowTitle("IntMusic Player");
    setGeometry(0, 0, 1042, 718);

    // 加载Config
    qDebug() << "Config --";
    ConfigManager& configManager = ConfigManager::instance();
    QSettings *intSetting = configManager.getSettings();
    qDebug() << configManager.getSettings();
    QStringList keys = intSetting->allKeys();

    // 遍历所有键值对并显示
    for (const QString &key : keys) {
        QVariant value = intSetting->value(key);
        QString line = QString("%1: %2").arg(key).arg(value.toString());
        qDebug() << line;
    }
    // QString configPath = configManager

    // Main Windows
    centralWidget = new QWidget(this);
    setCentralWidget(centralWidget);

    QVBoxLayout *mainLayout = new QVBoxLayout(centralWidget);

    // 创建 TabWidget
    mainTab = new IntMusicIndexTab(this);
    mainLayout->addWidget(mainTab,5);

    // MiniPlayer 控件
    miniPlayer = new MiniPlayer(this);
    mainLayout->addWidget(miniPlayer,1);

    // 菜单栏
    menubar = new QMenuBar(this);
    menuIntMusic = new QMenu("IntMusic", menubar);
    menuControl = new QMenu("控制", menubar);
    actionSetting = new QAction("Setting", this);
    actionPause = new QAction("Pause", this);
    actionStart = new QAction("Start", this);
    actionNext = new QAction("Next", this);
    actionPrevious = new QAction("Previous", this);
    menuIntMusic->addAction(actionSetting);
    menuControl->addAction(actionPause);
    menuControl->addAction(actionStart);
    menuControl->addAction(actionNext);
    menuControl->addAction(actionPrevious);
    menubar->addMenu(menuIntMusic);
    menubar->addMenu(menuControl);
    setMenuBar(menubar);

}

IntMusic::~IntMusic()
{

}


