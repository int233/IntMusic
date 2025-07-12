#ifndef INTMUSICINDEXTAB_H
#define INTMUSICINDEXTAB_H

#include <QWidget>
#include <QScrollArea>
#include <QListWidget>
#include <QLabel>
#include <QVBoxLayout>
#include <QStackedWidget>

#include "index.h"
#include "musiclist.h"
#include "setting.h"

#include <app/custom/FlexibleTabWidget/flexibletabwidget.h>

class IntMusicIndexTab : public QWidget
{
    Q_OBJECT
public:
    explicit IntMusicIndexTab(QWidget *parent = nullptr);
    // QTabWidget *MainTabWindows;
    FlexibleTabWidget *MainTabWindows;


private:
    QVBoxLayout *IndexTabLayout;

    QTabBar *topTabs;
    QTabBar *bottomTabs;
    QStackedWidget *stackedWidget;

    TabIndex *TabIndexContent;
    TabMusicList *TabMusicListContent;
    TabSetting *TabSettingContent;

signals:
};

#endif // INTMUSICINDEXTAB_H
