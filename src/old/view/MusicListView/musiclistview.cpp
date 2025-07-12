#include "musiclistview.h"
#include "app/util/PlayList/standardplaylist.h"


MusicListView::MusicListView(QWidget *parent)
    : QWidget(parent),pl_db(API::createPlayListDB()), player(&MusicService::instance())
{
    setupUI();
    loadMusicData();
}

void MusicListView::setupUI()
{
    QVBoxLayout *mainLayout = new QVBoxLayout(this);

    // 标题
    QLabel *titleLabel = new QLabel("音乐", this);
    titleLabel->setAlignment(Qt::AlignCenter);
    titleLabel->setStyleSheet("font-size: 18px; font-weight: bold; margin: 10px;");

    // 列表视图
    listView = new QListView(this);
    model = new QStandardItemModel(this);
    listView->setModel(model);
    listView->setEditTriggers(QAbstractItemView::NoEditTriggers);

    // 刷新按钮
    QPushButton *refreshButton = new QPushButton("刷新", this);
    connect(refreshButton, &QPushButton::clicked, this, &MusicListView::refreshMusicList);

    // 布局
    mainLayout->addWidget(titleLabel);
    mainLayout->addWidget(listView);
    mainLayout->addWidget(refreshButton);

    // 连接点击信号
    connect(listView, &QListView::clicked, this, &MusicListView::onItemClicked);
    connect(listView, &QListView::doubleClicked, this, &MusicListView::onItemDoubleClicked);
}

void MusicListView::loadMusicData()
{
    model->clear();

    QString debugTitle = "loadMusicData";

    qDebug() << debugTitle << ";";

    try {
        // 获取所有歌曲信息
        qDebug() << debugTitle << " - start get PlayList: AllSongs, ID: 0" ;
        QSharedPointer<PlayListInfo> allSongsPlayListInfo = pl_db->loadPlayListbyID(0);
        // QSharedPointer<StandardPlayList> allSongsPlayList = allSongsPlayListInfo->playlist;
        qDebug() << debugTitle << " - get allSongsPlayListInfo" ;
        // QHash<int, QSharedPointer<SongInfo>> allSongs = allSongsPlayListInfo->playlist->getSongs();
        // qDebug() << debugTitle << " - Retrieved songs count:" << allSongs.size();

        // if (allSongs.size() == 0){
        //     return;
        // }
        for (auto &songID : allSongsPlayListInfo->playlist->getSongIDs()){
            qDebug() << debugTitle << " - SongID: " << songID;
            auto songInfo = allSongsPlayListInfo->playlist->getSong(songID);
            qDebug() << debugTitle << " - Title: " << songInfo->title << ", album ID: "<< songInfo->albumID << ", 专辑演出者: " << songInfo->artists.first() << ", Path: " <<songInfo->filePath;
            QStandardItem *item = new QStandardItem();
            QString displayText = QString("%1\n艺术家: %2\n时长: %3")
                                                .arg(songInfo->title)
                                                .arg(songInfo->artists.join(", "))
                                                .arg(QTime::fromMSecsSinceStartOfDay(songInfo->durations*1000).toString("mm:ss"));
            item->setText(displayText);
            qDebug() << debugTitle << " - Generated display text:" << displayText;
            item->setData(songInfo->filePath, Qt::UserRole); 
            item->setData(QVariant::fromValue(allSongsPlayListInfo), Qt::UserRole + 1);
            item->setData(QVariant::fromValue(songInfo), Qt::UserRole + 2);
            // qRegisterMetaType<SongInfo>("SongInfo");
            // qRegisterMetaType<QSharedPointer<PlayListInfo>>("QSharedPointer<PlayListInfo>");
            model->appendRow(item);
        }

        // for(auto &songInfo : allSongs.values()){
        //     qDebug() << debugTitle << " - Title: " << songInfo->title << ", album ID: "<< songInfo->albumID << ", 专辑演出者: " << songInfo->artists.first() << ", Path: " <<songInfo->filePath;
        //     QStandardItem *item = new QStandardItem();
        //     QString displayText = QString("%1\n艺术家: %2\n时长: %3")
        //                                         .arg(songInfo->title)
        //                                         .arg(songInfo->artists.join(", "))
        //                                         .arg(QTime::fromMSecsSinceStartOfDay(songInfo->durations*1000).toString("mm:ss"));
        //     item->setText(displayText);
        //     qDebug() << debugTitle << " - Generated display text:" << displayText;
        //     item->setData(songInfo->filePath, Qt::UserRole); 
        //     item->setData(QVariant::fromValue(allSongsPlayListInfo), Qt::UserRole + 1);
        //     item->setData(QVariant::fromValue(songInfo), Qt::UserRole + 2);
        //     // qRegisterMetaType<SongInfo>("SongInfo");
        //     // qRegisterMetaType<QSharedPointer<PlayListInfo>>("QSharedPointer<PlayListInfo>");
        //     model->appendRow(item);
        // }
    } catch (const std::exception &e) {
        QMessageBox::critical(this, "错误", QString("加载音乐数据失败: %1").arg(e.what()));
    }
}

void MusicListView::refreshMusicList()
{
    loadMusicData();
}

void MusicListView::onItemClicked(const QModelIndex &index)
{

    QString debugTitle = "onItemClicked";

    QString filePath = index.data(Qt::UserRole).toString();
    qDebug() << debugTitle << " - Clicked: " << filePath;
    
}

void MusicListView::onItemDoubleClicked(const QModelIndex &index) {

    QString debugTitle = "onItemDoubleClicked";

    QString filePath = index.data(Qt::UserRole).toString();
    QSharedPointer<PlayListInfo> playListInfo = index.data(Qt::UserRole + 1).value<QSharedPointer<PlayListInfo>>();
    QSharedPointer<SongInfo> songInfo = index.data(Qt::UserRole + 2).value<QSharedPointer<SongInfo>>();
    qDebug() <<  debugTitle << " - DoubleClicked: " << filePath;

    // 发送歌单和歌曲id至Player
    // player
    player->setPlayList(playListInfo);
    player->setSong(songInfo->songID);
    player->play();

}