#pragma once

#include <QSqlDatabase>
#include <QSqlQuery>
#include <QDir>
#include <QDirIterator>
#include <QSqlError>

#include "app/util/Interface/ialbum.h"
#include "app/util/Interface/icache.h"
#include "app/util/Interface/icharacter.h"
#include "app/util/Interface/igenre.h"
#include "app/util/Interface/ilang.h"
#include "app/util/Interface/iplaylist.h"
#include "app/util/Interface/isong.h"
#include "app/util/Interface/musicdatastruct.h"
#include "app/util/Config/configmanager.h"



class MusicLibrary : public QObject,
                                  public IPlayList,
                                  public IAlbum,
                                  public ICache,
                                  public ICharacter,
                                //   public IGenre,
                                //   public ILang,
                                  public ISong
{
    Q_OBJECT

public:
    static MusicLibrary &instance();
    ~MusicLibrary();

    // cache
    // 歌曲信息缓存
    QHash<int, QSharedPointer<SongInfo>> songCache;
    // 专辑信息缓存
    QHash<int, QSharedPointer<AlbumInfo>> albumCache;
    QHash<int, QSharedPointer<PlayListInfo>> playListCache;

    // 通过修改时间检查缓存是否失效
    // bool cacheIsValid(const int &id, const QString &type) override;
    // 更新歌曲缓存
    // bool updateSongCache(const int &songID) override;
    // 判断歌曲缓存是否存在
    // bool songCacheExist(const int &songID) override;
    // 读取歌曲缓存
    QSharedPointer<SongInfo> getSongCache(const int songID) override;
    // 更新专辑缓存
    // bool updateAlbumCache(const int &albumID) override;
    // 判断专辑缓存是否存在
    // bool albumCacheExist(const int &albumID) override;
    // 读取歌曲缓存
    QSharedPointer<AlbumInfo> getAlbumCache(const int albumID) override;


    // PlayList
    // 向数据库中插入和更新播放列表
    int insertPlayList(const QString &name, const QVector<int> songIDs = {}) override;
    // 删除数据库中的播放列表
    bool deletePlayList(const int playListID) override;
    // 从数据库中载入播放列表
    QSharedPointer<PlayListInfo> loadPlayListbyName(const QString &name)  override;
    QSharedPointer<PlayListInfo> loadPlayListbyID(const int playListID)  override;
    // 从根据播放列表id，获取所有song_id
    QVector<int> getSongIDbyPlayListID(const int playListID) override;

    // Song
    // 本地歌曲操作
    // 根据文件路径读取本地歌曲信息
    QSharedPointer<SongInfo> readLocalSong(const QString &path) override;


    // 写入数据库
    // 将歌曲信息写入至数据库，若存在则覆盖
    // 还需确定AlbumID
    int insertSong( const QSharedPointer<SongInfo> songInfo) override;
    // 将本地扫描的歌曲位置存入数据库
    bool insertScanResult(const QStringList &musicFiles) override;
    // 解析扫描到的歌曲标签，并存入数据库
    bool parseInsertResult() override;

    // 读取数据库
    // 检查歌曲是否存在于数据库中
    int songExists(const QString &path) override;
    // 从数据库中根据歌曲id查询信息
    QSharedPointer<SongInfo> getSongInfobyID(const int songID) override;
    // 根据不同信息查询歌曲id
    QVector<int> searchSong(const QString &key, const QVariant &value) override;

    // Album
    // 本地
    QSharedPointer<AlbumInfo> readLocalSongAlbum(const QString &path) override;

    // 写入数据库
    int insertAlbum( const QSharedPointer<AlbumInfo> albumInfo) override;

    // 读取数据库
    // 检查专辑是否存在于数据库中
    int albumExists(const QString &albumName, const QString &albumFirstArtist, const int albumReleaseYear)  override;
    // 从数据库中根据专辑id获取歌曲信息
    QVector<QSharedPointer<SongInfo>> getSongInfobyAlbumID(const int albumID) override;
    // 从数据库中根据专辑id查询信息
    QSharedPointer<AlbumInfo> getAlbumInfobyID(const int albumID) override;
    // 根据不同信息查询专辑id
    QVector<int> searchAlbum(const QString &key, const QVariant &value) override;
    // 将歌曲添加至专辑
    bool pairAlbumSong(const int albumID, const int songID , const int track_number = 0, const int disc_number = 0) override;

    // Character
    // 从本地歌曲中获取人物信息
    QVector<QSharedPointer<CharacterInfo>> readLocalSongCharacter(const QString &path) override;

    // 插入人物
    int insertCharacter(QSharedPointer<CharacterInfo> characterInfo)override;
    // 检查人物是否存在
    int characterExists(const QString& name, const QString& foreign, const int overlapID = 0) override;

    // 插入歌曲和人物的关系
    bool pairSongCharacter(const int songID, const int characterID, const QString &role) override;
    // 插入专辑和人物的关系
    bool pairAlbumCharacter(const int AlbumID, const int characterID, const QString &role) override;

    // 根据人物id获取人物信息
    // 仅有id和姓名
    QSharedPointer<CharacterInfo> getCharacterInfobyID(const int characterID)  override;
    // 根据专辑id获取所有人物
    // 包括角色、姓名
    QVector<QSharedPointer<CharacterInfo>> searchCharacterbyAlbumID(const int albumID) override;
    // 根据歌曲id获取所有人物
    QVector<QSharedPointer<CharacterInfo>> searchCharacterbySongID(const int songID) override;
    // 根据不同信息查询人物id
    // QVector<int> searchCharacter(const QString &key, const QVariant &value) override;
    // 根据人物id查询所有歌曲
    QVector<QSharedPointer<SongInfo>> searchSongbyCharacterID(const int characterID) override;
    // 根据人物id查询所有专辑
    QVector<QSharedPointer<AlbumInfo>> searchAlbumbyCharacterID(const int haracterID) override;


private:
    explicit MusicLibrary(QObject *parent = nullptr);
    ConfigManager &configManager;

    QString databasePath;
    QStringList getLibraryPaths() const;
    QSqlDatabase m_db;
    QString splitPartten = "[;,/]";
    void initializeDatabase();
    void createTables();
    void closeDatabase();

    // 数据库连接配置
    static constexpr const char* DB_CONNECTION_NAME = "MUSIC_LIB_CONN";
    // static constexpr const char* DB_CACHE_CONN_NAME = "MUSIC_CACHE_CONN";
    // 检查表是否存在
    bool tableExists(const QString &tableName);


    // 分割字符串
    QStringList splitString(const QString &str);
    QStringList splitString(const QStringList &strlist);
    // 格式化年月日
    DateInfo formatDate(const QString &dateString);
    // 从临时扫描结果的表中获取音乐路径
    QStringList retrieveMusicFiles() const;
};