#ifndef MUSICLISTVIEW_H
#define MUSICLISTVIEW_H

#include <QWidget>
#include <QListView>
#include <QStandardItemModel>
#include <QVBoxLayout>
#include <QLabel>
#include <QDebug>
#include <QMessageBox>
#include <QPushButton>

#include "app/util/Interface/musicdatastruct.h"
#include "app/util/Interface/iplaylist.h"
#include "app/util/MusicService/musicservice.h"
#include "app/util/Interface/api.h"

class MusicListView : public QWidget {
    Q_OBJECT

public:
    explicit MusicListView(QWidget *parent = nullptr);
    void refreshMusicList();

private:
    void setupUI();
    void loadMusicData();

    QListView *listView;
    QStandardItemModel *model;
    IPlayList *pl_db;
    MusicService *player;

    QPushButton *refreshButton;

private slots:
    void onItemClicked(const QModelIndex &index);
    void onItemDoubleClicked(const QModelIndex &index);
};

#endif // MUSICLISTVIEW_H
