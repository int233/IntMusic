#include "intmusicindextab.h"

IntMusicIndexTab::IntMusicIndexTab(QWidget *parent)
    : QWidget{parent}
{
    // 主布局
    QVBoxLayout *IndexTabLayout = new QVBoxLayout(this);

    // 创建 TabWidget
    MainTabWindows = new FlexibleTabWidget(this);
    MainTabWindows->setTabPosition(QTabWidget::West);
    MainTabWindows->setTabShape(QTabWidget::Triangular);
    MainTabWindows->setElideMode(Qt::ElideLeft);
    MainTabWindows->setUsesScrollButtons(true);

    // 首页 Tab
    TabIndexContent = new TabIndex(this);


    // MusicList Tab
    TabMusicListContent = new TabMusicList(this);
    MainTabWindows->addMiddleTab(TabMusicListContent, "音乐");

    //Setting Tab
    TabSettingContent = new TabSetting(this);
    MainTabWindows->addBottomTab(TabSettingContent, "设置");

    MainTabWindows->addTab(TabIndexContent, "首页");

    // 将 TabWidget 添加到主布局
    IndexTabLayout->addWidget(MainTabWindows);

}
