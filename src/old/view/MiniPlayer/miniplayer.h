#ifndef MINIPLAYER_H
#define MINIPLAYER_H

#include <QWidget>
#include <QGraphicsView>
#include <QLabel>
#include <QSlider>
#include <QPushButton>
#include <QTimeEdit>

#include <QHBoxLayout>

#include "app/util/MusicService/musicservice.h"
#include "app/util/Interface/musicdatastruct.h"

class MiniPlayer : public QWidget
{
    Q_OBJECT
public:
    explicit MiniPlayer(QWidget *parent = nullptr);
    
    QSlider* getProgressSlider() const { return MiniPlayerProgress; }
    QTimeEdit* getCurrentTimeEdit() const { return MiniPlayerCurrentTime; }
    QTimeEdit* getTotalTimeEdit() const { return MiniPlayerTotalTime; }
    QPushButton* getPauseButton() const { return MiniPlayerPause; }

private slots:
    void updatePlayPauseIcon(QMediaPlayer::PlaybackState state);
    void togglePlayPause(bool play);
    void togglePlayPrevious(bool play);
    void displaySongInfo(QSharedPointer<SongInfo>  songInfo);
    void updateSongTitle(QString title);
    void updateAlbumTitle(QString title);
    QTime getTimeObj(int seconds);
    void updateTotalTime(qint64 durations);
    void initProgressBar(qint64 durations);
    void updateCurrentTime(qint64 durations);
    void updateProgressBar(qint64 position);
    void seekPosition(int position);
    void updateSongInfo();


private:
    MusicService *player;
    // MiniPlayer 控件
    QWidget *MiniAlbum;
    QGraphicsView *AlbumImage;
    QWidget *MusicTitles;
    QLabel *PlayingMusicTitle;
    QLabel *PlayingAblumTitle;
    QWidget *MiniSlider;
    QTimeEdit *MiniPlayerCurrentTime;
    QSlider *MiniPlayerProgress;
    QTimeEdit *MiniPlayerTotalTime;
    QWidget *MiniControler;
    QPushButton *MiniPlayerOrderMode;
    QPushButton *MiniPlayerPrevious;
    QPushButton *MiniPlayerPause;
    QPushButton *MiniPlayerNext;
    QPushButton *MiniPlayerSound;

};

#endif // MINIPLAYER_H


