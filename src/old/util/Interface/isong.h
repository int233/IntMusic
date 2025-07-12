#pragma once
#include <QString>
#include "musicdatastruct.h" 

struct SongInfo;

class ISong {
public:
    virtual ~ISong() = default;
    
    // 本地歌曲操作
    // 根据文件路径读取本地歌曲信息
    virtual QSharedPointer<SongInfo> readLocalSong(const QString &path) = 0;

    // 写入数据库
    // 将歌曲信息写入至数据库，若存在则覆盖
    virtual int insertSong( const QSharedPointer<SongInfo> songInfo) = 0;
    // 将本地扫描的歌曲位置存入数据库
    virtual bool insertScanResult(const QStringList &musicFiles)  = 0;
    // 解析扫描到的歌曲标签，并存入数据库
    virtual bool parseInsertResult()  = 0;

    // 读取数据库
    // 检查歌曲是否存在于数据库中
    virtual int songExists(const QString &path) = 0;
    // 从数据库中根据歌曲id查询信息
    virtual QSharedPointer<SongInfo> getSongInfobyID(const int songID) = 0;
    // 根据不同信息查询歌曲id
    virtual QVector<int> searchSong(const QString &key, const QVariant &value) = 0;
};