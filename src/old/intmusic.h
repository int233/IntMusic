#ifndef INTMUSIC_H
#define INTMUSIC_H

#include <QMainWindow>
#include <QListWidgetItem>
#include <QMainWindow>
#include <QTabWidget>
#include <QScrollArea>
#include <QListWidget>
#include <QLabel>
#include <QSlider>
#include <QPushButton>
#include <QTimeEdit>
#include <QGraphicsView>
#include <QMenuBar>
#include <QMenu>
#include <QAction>

#include <QVBoxLayout>

#include <app/view/MiniPlayer/miniplayer.h>
#include <app/view/IntMusicIndexTab/intmusicindextab.h>
#include "app/util/Config/configmanager.h"

QT_BEGIN_NAMESPACE
namespace Ui { class IntMusic; }
QT_END_NAMESPACE

class IntMusic : public QMainWindow
{
    Q_OBJECT

public:
    IntMusic(QWidget *parent = nullptr);
    ~IntMusic();

private slots:

private:
    QWidget *centralWidget;

    // 首页控件
    IntMusicIndexTab *mainTab;

    // 菜单栏
    QMenuBar *menubar;
    QMenu *menuIntMusic;
    QMenu *menuControl;
    QAction *actionSetting;
    QAction *actionPause;
    QAction *actionStart;
    QAction *actionNext;
    QAction *actionPrevious;

    // MiniPlayer
    MiniPlayer *miniPlayer;
};
#endif // INTMUSIC_H
