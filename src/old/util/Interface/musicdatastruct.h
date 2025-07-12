#ifndef MUSICDATASTRUCT_H
#define MUSICDATASTRUCT_H

#include <QString>
#include <QList>
#include <QDate>
#include <QRegularExpression>

// #include "iplaylist.h"
// #include "app/util/PlayList/playlist.h"
// #include "app/util/PlayList/standardplaylist.h"
// #include "app/util/PlayList/smartplaylist.h"

class PlayList;
// class SmartPlayList;
// class StandardPlayList;

struct DateInfo {
    // QDate date = QDate(1, 1, 1);
    // // 1: year, 2: year/month, 3: year/month/day
    // int level = 0;

    int year;
    int month;
    int day;
    int level;
    DateInfo(int y = 0, int m = 0, int d = 0, int l = 0) 
    : year(y), month(m), day(d) , level(l){}

    QString toString() const {
        switch(level) {
        case 1:  // 仅年份
            return QString::number(year);
        case 2:  // 年-月（月份补零）
            return QString("%1-%2")
                .arg(year)
                .arg(month, 2, 10, QLatin1Char('0'));
        case 3:  // 年-月-日（月日补零）
            return QString("%1-%2-%3")
                .arg(year)
                .arg(month, 2, 10, QLatin1Char('0'))
                .arg(day, 2, 10, QLatin1Char('0'));
        case 0:  // 无日期信息
        default:
            return "None";
        }
    }
};

struct AlbumInfo {
    int albumID = -1;
    // ARTIST
    // TagLib::Tag::album()
    QString albumName;
    // ALBUM ARTIST
    // file.file()->properties()["ALBUMARTIST"]
    QStringList albumArtists;
    // PUBLISHER
    // file.file()->properties()["PUBLISHER"]
    QStringList publishers;
    // ALBUM SCORE
    // file.file()->properties()["ALBUM SCORE"]
    int albumScore = 0;
    // ALBUMVERSION
    // file.file()->properties()["ALBUMVERSION"]
    QString albumVersion;
    QString albumCoverPath;
    DateInfo originalReleaseTime;
    // RELEASE TIME
    // TagLib::Tag::year()
    DateInfo albumReleaseTime;
    // COUNTRY
    // file.file()->properties()["COUNTRY"]
    QString country;
    // TOTALDISCS
    // file.file()->properties()["TOTALDISCS"]
    int totalDiscs;
    QVector<int> tracksCounts;
    QStringList tracksTitles;
    QVector<DateInfo> tracksReleaseTimes;
    QVector<DateInfo> tracksStartTimes;
    QVector<DateInfo> tracksEndTimes;
    QStringList tracksCoverPaths;
    // LANGUAGE
    // file.file()->properties()["LANGUAGE"]
    QStringList languages;
    // GENRE
    // TagLib::Tag::genre()
    QStringList genres;
    // LIVEEVENT
    // file.file()->properties()["LIVEEVENT"]
    QString liveEvent;
    // LIVEEVENTCOUNT
    // file.file()->properties()["LIVEEVENTCOUNT"]
    QString liveEventCount;
    QDateTime modified;

    AlbumInfo(const QString &name)
    : albumName(name){}
};

struct CharacterInfo{
    int characterID = -1;
    QString characterName;
    QString foreignName;
    QString portrait_path = "";
    int overlap_id = 0;
    QString role;
    QDateTime modified;

    CharacterInfo(const QString& role,const QString& name, const QString& foreign)
    : role(role){
        // 检查是否仅有一个值有内容
        bool hasName = !name.isEmpty();
        bool hasForeign = !foreign.isEmpty();

        if (hasName && !hasForeign) {
            // 如果只有 characterName 有值，且不包含中文字符，则放入 foreignName
            if (!containsChinese(name)) {
                foreignName = name;
                characterName.clear();
            } else {
                characterName = name;
            }
        } else if (!hasName && hasForeign) {
            // 如果只有 foreignName 有值，且不包含中文字符，则放入 foreignName
            if (!containsChinese(foreign)) {
                foreignName = foreign;
            } else {
                characterName = foreign;
                foreignName.clear();
            }
        } else {
            // 如果两个值都有值或都没有值，则直接赋值
            characterName = name;
            foreignName = foreign;
        }
    }
    private:
        // 检查字符串是否包含中文字符
        static bool containsChinese(const QString& text) {
            QRegularExpression regex("[\u4e00-\u9fff]"); // 中文字符的 Unicode 范围
            return regex.match(text).hasMatch();
        }
};



struct SongInfo {
    int songID = -1;
    QString title;
    QString albumName;
    QStringList artists;
    // 时长(s)
    int durations = -1;
    // 文件大小(KB)
    int fileSize = -1;
    QString filePath;
    // 专辑ID: 单曲设置为0，存在专辑则设置为专辑ID
    int albumID = -1;
    int totalTracks = 0;
    int totalDiscs = 0;
    int trackNumber = 0;
    int discNumber = 0;
    // 是否喜爱
    // FAVORITE、LOVE RATING、LOVE任意一个标签中有值则为喜爱
    bool isFavorite = false;
    // 是否现场
    // LIVE标签有值则为现场
    bool isLive = false;
    // 是否单曲
    // SINGLE标签有值则为单曲
    bool isSingle = false;
    QString liveEvent;
    QString liveEventCount;
    // 是否翻唱
    // COVER标签有值则为翻唱
    bool isCover = false;
    // 是否串烧
    // MASHUP标签有值则为串烧
    bool isMashup = false;
    // ORDATE
    DateInfo originalReleaseDate;
    // RDATE
    DateInfo releaseDate;
    QVector<QSharedPointer<CharacterInfo>> characters;
    QSharedPointer<AlbumInfo> album;
    // tag->genre()
    QStringList genres;
    // LANGUAGE
    // file.file()->properties()["LANGUAGE"]
    QStringList languages;
    QDateTime modified;

    // SongInfo(const QString name)
    //     : title(name){}

    QStringList getCharacters(const QString &role, bool foreign = false){
        QStringList result;
        for (const QSharedPointer<CharacterInfo> &character : characters) {
            if (character->role == role) {
                bool hasName = !character->characterName.isEmpty();
                bool hasForeign = !character->foreignName.isEmpty();

                if (hasName && hasForeign) {
                    result.append(foreign ? character->foreignName : character->characterName);
                } else {
                    QString name = hasName ? character->characterName : character->foreignName;
                    if (!name.isEmpty()) {
                        result.append(name);
                    }
                }
            }
        }
        return result;
    }
};

struct PlayListInfo {
    int playListID;
    QString playListName;
    // QVector<int> songIDs;
    bool isSmart = false;
    bool isEmpty = false;
    PlayList* playlist = nullptr;
    QDateTime modified = QDateTime::currentDateTime();

    PlayListInfo(const int id, const QString &name, bool isSmart = false, QObject* parent = nullptr)
    : playListID(id),
    playListName(name),
    isSmart(isSmart),
    isEmpty(false),  
    playlist(nullptr),   
    modified(QDateTime::currentDateTime()) 
{}
};

#endif // MUSICDATASTRUCT_H