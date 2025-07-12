#include "musiclibrary.h"
#include "app/util/PlayList/standardplaylist.h"

#include <taglib/tag.h>
#include <taglib/fileref.h>
#include <taglib/tpropertymap.h>

MusicLibrary& MusicLibrary::instance() {
    static MusicLibrary instance;
    return instance;
}

MusicLibrary::MusicLibrary(QObject  *parent)
    : QObject(parent), configManager(ConfigManager::instance()) 
{
    QStringList libraryPaths = getLibraryPaths();
    databasePath = libraryPaths.first();
    qDebug() << "Library Path: " << databasePath;

    if (QSqlDatabase::contains(DB_CONNECTION_NAME)) {
        m_db = QSqlDatabase::database(DB_CONNECTION_NAME);
    } else {
        m_db = QSqlDatabase::addDatabase("QSQLITE", DB_CONNECTION_NAME);
        m_db.setDatabaseName(databasePath);
    }

    if (!m_db.open()) {
        qCritical() << "Database connection error:" << m_db.lastError().text();
        return;
    }
    initializeDatabase();
}

MusicLibrary::~MusicLibrary()
{
    closeDatabase();
}

void MusicLibrary::initializeDatabase()
{
    QSqlQuery query(m_db);
    if (!query.exec("PRAGMA foreign_keys = ON;")) {
        qCritical() << "Failed to enable foreign keys:" << query.lastError().text();
        return;
    }
    createTables();
}

void MusicLibrary::closeDatabase()
{
    if (m_db.isOpen()) {
        m_db.close();
    }
    QSqlDatabase::removeDatabase(DB_CONNECTION_NAME);
}


QStringList MusicLibrary::getLibraryPaths() const {
    QString libraryFolderPath = configManager.getSettings()->value("Common/ConfigPath/").toString() + "library/";

    const QString librarySubfix = "intlibrary";
    QStringList filePaths;

    // 检查目录是否存在
    QDir libraryDir(libraryFolderPath);
    if (!libraryDir.exists()) {
        qWarning() << "Library directory does not exist:" << libraryFolderPath;
    }

    // 使用 QDirIterator 遍历目录
    QDirIterator it(libraryFolderPath, QStringList() << "*." + librarySubfix, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        filePaths.append(it.next());
    }

    if (filePaths.isEmpty()) {
        qWarning() << "No library files found in:" << libraryFolderPath;
        QString defaultPath = configManager.GetHomeLibraryPath();
        QDir dir(defaultPath);
        if (!dir.exists()) {
            dir.mkpath(".");
        }
        filePaths.append(QDir::toNativeSeparators(dir.filePath("music.intlibrary")));
    }

    return filePaths;
}

bool MusicLibrary::tableExists(const QString &tableName) {
    QSqlQuery query(m_db);
    query.exec(QString("SELECT name FROM sqlite_master WHERE type='table' AND name='%1';").arg(tableName));

    if (query.next()) {
        return true;
    } else {
        return false;
    }
}

void MusicLibrary::createTables()
{
    QSqlQuery query(m_db);

    // MusicScan表
    /*
    music_id: 扫描到的音乐id，无意义
    music_path: 音乐文件位置
    */
   query.exec(
    "CREATE TABLE IF NOT EXISTS MusicsFound ("
    "    music_id       INTEGER PRIMARY KEY AUTOINCREMENT,"
    "    music_path     TEXT NOT NULL UNIQUE CHECK(music_path != ''),"
    "    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP"
    ");"
    );

    // Albums表（专辑信息）
    /*
    album_id: 专辑id
    album_name: 专辑名
    publisher: 发布者（公司名等）
    album_score: 专辑评分，0~5
    release_time: 专辑发布时间
    total_tracks: 专辑曲目总数
    total_discs: 专辑碟数
    created_at: 添加时间
    modified_at: 修改时间
    */
    query.exec(
        "CREATE TABLE IF NOT EXISTS Albums ("
        "    album_id       INTEGER PRIMARY KEY AUTOINCREMENT,"
        "    album_name     TEXT NOT NULL CHECK(album_name != ''),"
        "    album_first_artist     TEXT NOT NULL CHECK(album_first_artist != ''),"
        "    publisher      TEXT,"
        "    album_score    REAL CHECK(album_score BETWEEN 0 AND 5),"
        "    album_version  TEXT,"
        "    original_release_year   INTEGER,"
        "    original_release_month   INTEGER,"
        "    original_release_day   INTEGER,"
        "    original_release_level   INTEGER,"
        "    album_release_year   INTEGER,"
        "    album_release_month   INTEGER,"
        "    album_release_day   INTEGER,"
        "    album_release_level   INTEGER,"
        "    country        TEXT,"
        "    genres          TEXT,"
        "    total_discs    INTEGER,"
        "    cover_path     TEXT,"
        "    languages     TEXT,"
        "    live_event     TEXT,"
        "    live_event_count TEXT,"
        "    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,"
        "    modified_at    DATETIME DEFAULT CURRENT_TIMESTAMP"
        ");"
        );
    query.exec(
        "CREATE TABLE IF NOT EXISTS Tracks ("
        "    track_id       INTEGER PRIMARY KEY AUTOINCREMENT,"
        "    album_id     INTEGER CHECK(album_id > 0),"
        "    title          TEXT,"
        "    track_number   INTEGER CHECK(track_number > 0),"
        "    media_number   INTEGER CHECK(media_number > 0),"
        "    genres          TEXT,"
        "    languages     TEXT,"
        "    release_time   DATETIME,"
        "    start_time     DATETIME,"
        "    end_time       DATETIME,"
        "    cover_path     TEXT,"
        "    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,"
        ");"
        );
    // Characters表（角色信息）
    /*
    character_id
    character_name: 姓名
    character_foreign_name: 外文名
    portrait_path: 头像路径

    扫描音乐时，通过姓名和外文名匹配，若存在则使用已有角色，若不存在则插入新角色
    若需插入相同姓名的人，通过overlap_id区分，默认为0
    */
    query.exec(
        "CREATE TABLE IF NOT EXISTS Characters ("
        "    character_id             INTEGER PRIMARY KEY AUTOINCREMENT,"
        "    character_name           TEXT,"
        "    character_foreign_name   TEXT,"
        "    portrait_path            TEXT,"
        "    overlap_id               INTEGER DEFAULT 0,"
        "    created_at               DATETIME DEFAULT CURRENT_TIMESTAMP,"
        "    modified_at              DATETIME DEFAULT CURRENT_TIMESTAMP"
        ");"
        );

    // Songs表（歌曲核心信息）
    /*
    song_id
    title: 歌曲名称
    duration_ms: 歌曲时长（毫秒）
    file_size: 文件大小（KB）
    file_path: 文件位置
    album_id: 专辑
    track_number: 曲目次序
    disc_number: 碟号
    is_favorite: 是否喜爱
    is_live: 是否现场版
    is_single: 是否单曲
    live_event: 现场演出名称
    live_event_count: 现场演出场次
    is_cover: 是否翻唱
    is_mashup: 是否串烧
    release_time: 发布时间
    */
    query.exec(
        "CREATE TABLE IF NOT EXISTS Songs ("
        "    song_id        INTEGER PRIMARY KEY AUTOINCREMENT,"
        "    title          TEXT NOT NULL CHECK(title != ''),"
        "    durations    INTEGER CHECK(durations > 0),"
        "    first_artist   TEXT NOT NULL CHECK(first_artist != ''),"
        "    file_size      INTEGER CHECK(file_size > 0),"
        "    file_path      TEXT NOT NULL UNIQUE CHECK(file_path != ''),"
        "    album_id       INTEGER REFERENCES Albums(album_id) ON DELETE SET NULL,"
        "    track_number   INTEGER CHECK(track_number >= 0),"
        "    disc_number    INTEGER CHECK(disc_number >= 0),"
        "    total_track_number   INTEGER DEFAULT 1 CHECK(track_number >= 0),"
        "    total_disc_number    INTEGER DEFAULT 1 CHECK(disc_number >= 0),"
        "    is_favorite    BOOLEAN DEFAULT 0,"
        "    is_live        BOOLEAN DEFAULT 0,"
        "    is_single      BOOLEAN DEFAULT 0,"
        "    live_event     TEXT,"
        "    live_event_count TEXT,"
        "    is_cover       BOOLEAN DEFAULT 0,"
        "    is_mashup      BOOLEAN DEFAULT 0,"
        "    ori_release_year   INTEGER,"
        "    ori_release_month   INTEGER,"
        "    ori_release_day   INTEGER,"
        "    ori_release_level   INTEGER,"
        "    release_year   INTEGER,"
        "    release_month   INTEGER,"
        "    release_day   INTEGER,"
        "    release_level   INTEGER,"
        "    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,"
        "    modified_at     DATETIME DEFAULT CURRENT_TIMESTAMP"
        ");"
        );

    // 多对多关系表
    // SongCharacters

    // 角色列表
    if (!tableExists("RoleCategories")) {
        query.exec(
            "CREATE TABLE RoleCategories ("
            "    id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "    category TEXT NOT NULL,"
            "    role TEXT NOT NULL"
            ");"
        );
        if (query.lastError().isValid()) {
            qWarning() << "Failed to create table RoleCategories:" << query.lastError();
            return;
        }
        qDebug() << "Existing resources:" << QDir(":/").entryList();
        QFile file(":/resource/rolecategories.txt");
        if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            qWarning() << "Could not open rolecategories.txt:" << file.errorString();
            return;
        }
        QTextStream in(&file);
        QSqlQuery query(m_db);
        while (!in.atEnd()) {
            QString line = in.readLine();
            QStringList fields = line.split("\t");
    
            if (fields.size() != 2) {
                qWarning() << "Invalid line format in rolecategories.txt:" << line;
                continue;
            }
            QString category = fields[0];
            QString role = fields[1];
            query.prepare("INSERT INTO RoleCategories (category, role) VALUES (:category, :role)");
            query.bindValue(":category", category);
            query.bindValue(":role", role);
            if (!query.exec()) {
                qWarning() << "Failed to insert record into RoleCategories:" << query.lastError();
            }
        }
    } else {
        qDebug() << "Table RoleCategories already exists.";
    }

    // SongMetadata
    // Album-Songs
    query.exec(
        "CREATE TABLE IF NOT EXISTS AlbumSongs ("
        "    album_id             INTEGER REFERENCES Albums(album_id) ON DELETE CASCADE,"
        "    song_id               INTEGER REFERENCES Songs(song_id) ON DELETE CASCADE,"
        "    track_number     INTEGER,"
        "    disc_number       INTEGER,"
        "    PRIMARY KEY (album_id, song_id)"
        ");"
        );
    // Song-Character
    query.exec(
        "CREATE TABLE IF NOT EXISTS SongCharacters ("
        "    song_id        INTEGER REFERENCES Songs(song_id) ON DELETE CASCADE,"
        "    character_id   INTEGER REFERENCES Characters(character_id) ON DELETE CASCADE,"
        "    role           TEXT,"
        "    PRIMARY KEY (song_id, character_id, role)"
        ");"
        );
    // Album-Character
    query.exec(
        "CREATE TABLE IF NOT EXISTS AlbumCharacters ("
        "    album_id        INTEGER REFERENCES Albums(album_id) ON DELETE CASCADE,"
        "    character_id   INTEGER REFERENCES Characters(character_id) ON DELETE CASCADE,"
        "    role           TEXT,"
        "    PRIMARY KEY (album_id, character_id, role)"
        ");"
        );
    // Song-Genre
    query.exec(
        "CREATE TABLE IF NOT EXISTS SongGenres ("
        "    song_id        INTEGER REFERENCES Songs(song_id) ON DELETE CASCADE,"
        "    genre          TEXT,"
        "    PRIMARY KEY (song_id, genre)"
        ");"
        );

    // Song-Language
    query.exec(
        "CREATE TABLE IF NOT EXISTS SongLanguages ("
        "    song_id        INTEGER REFERENCES Songs(song_id) ON DELETE CASCADE,"
        "    language          TEXT,"
        "    PRIMARY KEY (song_id, language)"
        ");"
        );
    // Album-Genre
    query.exec(
        "CREATE TABLE IF NOT EXISTS AlbumGenres ("
        "    album_id        INTEGER REFERENCES Albums(album_id) ON DELETE CASCADE,"
        "    genre          TEXT,"
        "    PRIMARY KEY (album_id, genre)"
        ");"
        );

    // Album-Language
    query.exec(
        "CREATE TABLE IF NOT EXISTS AlbumLanguages ("
        "    album_id        INTEGER REFERENCES Albums(album_id) ON DELETE CASCADE,"
        "    language          TEXT,"
        "    PRIMARY KEY (album_id, language)"
        ");"
        );

    // 歌单
    // 歌单信息
    query.exec(
        "CREATE TABLE IF NOT EXISTS PlayList ("
        "    playlist_id        INTEGER PRIMARY KEY AUTOINCREMENT,"
        "    name          TEXT UNIQUE"
        ");"
        );
    // 初始的歌单信息
    if (!query.exec(
        "INSERT OR IGNORE INTO PlayList (playlist_id, name) VALUES "
        "(0, 'AllSongs'), (1, 'TempSongs');"
    )) {
        qDebug() << "Insert data error:" << query.lastError();
    }
    

    // 歌单和歌曲的关系
    query.exec(
        "CREATE TABLE IF NOT EXISTS SongsPlayList ("
        "    playlist_id       INTEGER REFERENCES PlayList(playlist_id) ON DELETE CASCADE,"
        "    song_id          INTEGER REFERENCES Songs(song_id) ON DELETE CASCADE"
        ");"
        );

    // 其他索引
    query.exec("CREATE INDEX IF NOT EXISTS idx_songs_album ON Songs(album_id);");
    query.exec("CREATE INDEX IF NOT EXISTS idx_song_characters ON SongCharacters(character_id);");
}

QStringList MusicLibrary::splitString(const QString &str){
    QStringList newstr;
    if (!str.isEmpty()) {
        // 使用正则表达式分割字符串（支持 ; , / 等分隔符）
        QRegularExpression regex(splitPartten);
        newstr = str.split(regex, Qt::SkipEmptyParts);
        // 去除前后空格
        for (QString& s : newstr) {
            s = s.trimmed();
        }
    }
    return newstr;
}

QStringList MusicLibrary::splitString(const QStringList &strlist){

    QString debugTitle = "splitString";

    QStringList newstrlist;
    if (!strlist.isEmpty()) {
        foreach(const QString &str, strlist){
            newstrlist.append(splitString(str));
        }
    }
    return newstrlist;
}

DateInfo MusicLibrary::formatDate(const QString &dateString){

    QString debugTitle = "formatDate";

    DateInfo date;
    if (dateString.isEmpty()) {
        return DateInfo(); 
    }

    // 使用正则表达式匹配日期格式
    QRegularExpression regex(R"((\d{4})[./-]?(\d{1,2})?[./-]?(\d{1,2})?)");
    QRegularExpressionMatch match = regex.match(dateString);

    if (!match.hasMatch()) {
        return DateInfo(); 
    }
    
    // 提取年、月、日
    int level = 1;
    int year = match.captured(1).toInt(); 
    int month = match.captured(2).isEmpty() ? 1 : match.captured(2).toInt(); 
    int day = match.captured(3).isEmpty() ? 1 : match.captured(3).toInt();


    if (match.captured(2).isEmpty()) {
        level = 1;
    } else if (match.captured(3).isEmpty()) {
        level = 2;
    } else {
        level = 3;
    }

    // 检查日期的有效性
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
        return DateInfo(); 
    }
    return DateInfo(year, month, day, level);
}

QStringList MusicLibrary::retrieveMusicFiles() const {
    QStringList musicFiles;

    if (!m_db.isOpen()) {
        qCritical() << "Database is not open";
        return musicFiles;
    }

    QSqlQuery query(m_db);
    const QString sql = "SELECT music_path FROM MusicsFound";  // 确保表名与插入时一致
    
    if (!query.exec(sql)) {
        qCritical() << "Failed to execute query:" << query.lastError().text();
        return musicFiles;
    }

    while (query.next()) {
        const QString path = query.value("music_path").toString();
        if (!path.isEmpty()) {  // 可选：过滤空路径
            musicFiles.append(path);
        }
    }

    qDebug() << "Retrieved" << musicFiles.size() << "music files from database";
    return musicFiles;
}

QSharedPointer<SongInfo> MusicLibrary::getSongCache(const int songID) {

    QSharedPointer<SongInfo> tempSongInfo = getSongInfobyID(songID);

    QDateTime lastLocalModified;
    QDateTime lastLibModified;

    lastLibModified = tempSongInfo->modified;

    if (songCache.contains(songID)){
        QSharedPointer<SongInfo> localSongInfo = songCache.value(songID);
        lastLocalModified = localSongInfo->modified;
        if (lastLocalModified == lastLibModified){
            return localSongInfo;
        } else {
            songCache.insert(songID, tempSongInfo);
            return tempSongInfo;
        }
    } else {
        songCache.insert(songID, tempSongInfo);
        return tempSongInfo;
    }
}

QSharedPointer<AlbumInfo> MusicLibrary::getAlbumCache(const int albumID) {

    QSharedPointer<AlbumInfo> tempAlbumInfo = getAlbumInfobyID(albumID);

    QDateTime lastLocalModified;
    QDateTime lastLibModified;

    lastLibModified = tempAlbumInfo->modified;

    if (albumCache.contains(albumID)){
        QSharedPointer<AlbumInfo> localAlbumInfo = albumCache.value(albumID);
        lastLocalModified = localAlbumInfo->modified;
        if (lastLocalModified == lastLibModified){
            return localAlbumInfo;
        } else {
            albumCache.insert(albumID, tempAlbumInfo);
            return tempAlbumInfo;
        }
    } else {
        albumCache.insert(albumID, tempAlbumInfo);
        return tempAlbumInfo;
    }
}



int MusicLibrary::insertPlayList(const QString &name, const QVector<int> songIDs){

    QString debugTitle = "insertPlayList";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return false;
    }

    QSqlQuery query(m_db);

    // 检查歌单是否存在
    query.prepare("SELECT playlist_id FROM PlayList WHERE "
        "name = :playListName");
    query.bindValue(":playListName", name);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check playlist existence failed:" << query.lastError();
        m_db.rollback();
        return -1;
    }

    if (!m_db.transaction()) {
        qWarning() << "Failed to start transaction:" << m_db.lastError();
        return -1;
    }

    int playListID;

    if (query.next()) {
        // 从SongsPlayList中删除旧歌单的歌曲
        playListID = query.value(0).toInt();
        if (songIDs.isEmpty()){
            qDebug() << debugTitle << " - Found Playlist exist, cancel insert: " << playListID;
            return playListID;
        }
        query.prepare("DELETE FROM SongsPlayList WHERE playlist_id = :playListID");
        query.bindValue(":playListID", playListID);
        if (!query.exec()) {
            qDebug() << debugTitle << " - Delete failed:" << query.lastError().text();
        } else {
            qDebug() << debugTitle << " - Delete success" << query.numRowsAffected() << "rows";
        }

    }  else {
        // 在PlayList中添加新歌单
        query.prepare("INSERT INTO PlayList ("
            "name"
            ") VALUES ("
            ":playListName"
            ")"
        );
        query.bindValue(":playListName", name);
        qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
        qDebug() << debugTitle << " - Bound values:" << query.boundValues();
        if (!query.exec()) {
            qWarning() << "Insert playlist failed:" << query.lastError();
            m_db.rollback();
            return -1;
        }
        playListID = query.lastInsertId().toInt();
    }

    if (songIDs.isEmpty()){
        qDebug() << debugTitle << " - Empty Playlist Inserted: " << playListID;
        return playListID;
    }
    

    // 向歌单中添加新歌曲
    for (const int &songID : songIDs){
        query.prepare("INSERT INTO SongsPlayList ("
            "playlist_id, song_id "
            ") VALUES ("
            ":playListID, :songID "
            ")");
        query.bindValue(":playListID", playListID);
        query.bindValue(":songID", songID);
    
        qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
        qDebug() << debugTitle << " - Bound values:" << query.boundValues();
    
        if (!query.exec()) {
            if (query.lastError().nativeErrorCode() == "2067") { // SQLite 的唯一性错误代码
                qDebug() << debugTitle << " - Song already exists, skipping insertion.";
                m_db.rollback();
                return -1;
            } else {
                qWarning() << debugTitle << " - Insert song failed:" << query.lastError();
                m_db.rollback();
                return -1;
            }
        }
    }


    // int newSongID = query.lastInsertId().toInt();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Failed to insert song-character:" << query.lastError();
        m_db.rollback();
        return -1;
    }

    if (!m_db.commit()) {
        qWarning() << debugTitle << " - Failed to commit transaction:" << m_db.lastError();
        return -1;
    }

    return playListID;
}


bool MusicLibrary::deletePlayList(const int playListID){

    QString debugTitle = "deletePlayList";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return false;
    }

    QSqlQuery query(m_db);

    query.prepare("DELETE  FROM PlayList WHERE playlist_id = :playListID");
    query.bindValue(":playListID", playListID);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Delete playlist failed:" << query.lastError();
        return false;
    }

    if (query.numRowsAffected() <= 0) {
        qWarning() << debugTitle << " - No playlist found with ID:" << playListID;
        return false;
    }

    return true;
}

QSharedPointer<PlayListInfo> MusicLibrary::loadPlayListbyID(const int playListID){

    QString debugTitle = "loadPlayListbyID";

    if (playListCache.contains(playListID)) {
        qDebug() << debugTitle << " - Cache hit for ID" << playListID;
        return playListCache.value(playListID);
    }

    QSharedPointer<PlayListInfo>  playListInfo;

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QSharedPointer<PlayListInfo>();
    }

    QSqlQuery query(m_db);

    // 检查歌单是否存在
    query.prepare("SELECT playlist_id, name FROM PlayList WHERE playlist_id = :playlistID");
    query.bindValue(":playlistID", playListID);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check playlist existence failed:" << query.lastError();
        return QSharedPointer<PlayListInfo>();
    }
    if (!query.next()) {
        qWarning() << debugTitle << " - Playlist " << playListID << "not exists";
    }

    QString playListName = query.value("name").toString();

    qDebug() << debugTitle << " - Playlist: " << playListName << ", PlaylistID:" << playListID;
    
    QSharedPointer<PlayListInfo> tempPlayListInfo(new PlayListInfo(playListID, playListName));
    qDebug() << debugTitle << " - Playlist: " << playListName << ", PlaylistID:" << playListID << ", new QSharedPointer<PlayListInfo> created";
    tempPlayListInfo->playlist = new StandardPlayList(playListID, playListName);
    tempPlayListInfo->isEmpty = !(tempPlayListInfo->playlist->size() >0);
    qDebug() << debugTitle << " - Playlist: " << playListName << ", PlaylistID:" << playListID << ", new StandardPlayList created";

    return tempPlayListInfo;
}

QSharedPointer<PlayListInfo> MusicLibrary::loadPlayListbyName(const QString &name){

    QString debugTitle = "loadPlayListbyName";

    QSharedPointer<PlayListInfo>  playListInfo;

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QSharedPointer<PlayListInfo>();
    }

    QSqlQuery query(m_db);

    // 检查歌单是否存在
    query.prepare("SELECT playlist_id, name FROM PlayList WHERE name = :playListName");
    query.bindValue(":playListName", name);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check playlist existence failed:" << query.lastError();
        return QSharedPointer<PlayListInfo>();
    }
    if (!query.next()) {
        qWarning() << debugTitle << " - Playlist " << name << "not exists:";
    }

    int playListID = query.value("playlist_id").toInt();

    if (playListCache.contains(playListID)) {
        qDebug() << debugTitle << " - Cache hit via ID" << playListID;
        return playListCache.value(playListID);
    }

    qDebug() << debugTitle << " - Playlist: " << name << ", PlaylistID:" << playListID;

    QSharedPointer<PlayListInfo> tempPlayListInfo(new PlayListInfo(playListID, name));
    qDebug() << debugTitle << " - Playlist: " << name << ", PlaylistID:" << playListID << ", new QSharedPointer<PlayListInfo> created";
    tempPlayListInfo->playlist = new StandardPlayList(playListID, name);
    tempPlayListInfo->isEmpty = !(tempPlayListInfo->playlist->size() >0);
    qDebug() << debugTitle << " - Playlist: " << name << ", PlaylistID:" << playListID << ", new StandardPlayList created";

    return tempPlayListInfo;
}

QVector<int> MusicLibrary::getSongIDbyPlayListID(const int playListID){

    QString debugTitle = "getSongIDbyPlayListID";

    QVector<int> songIDs;

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QVector<int>();
    }

    QSqlQuery query(m_db);

    // 检查歌单是否存在
    query.prepare("SELECT playlist_id FROM PlayList WHERE "
        "playlist_id = :playlistID");
    query.bindValue(":playlistID", playListID);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check playlist existence failed:" << query.lastError();
        m_db.rollback();
        return QVector<int>();
    }
    if (!query.next()) {
        // 不存在
        qWarning() << debugTitle << " - Playlist " << playListID << "not exists:";
    }

    // 读取数据
    if (playListID == 0){
        query.prepare("SELECT  song_id FROM Songs");
    } else {
        query.prepare("SELECT  song_id FROM SongsPlayList WHERE playlist_id = :playListID");
        query.bindValue(":playListID", playListID);
    }

    if (!query.exec()) {
        qCritical() << debugTitle << " - Failed to execute query:" << query.lastError().text();
    } else {
        while(query.next()){
            const int songID = query.value("song_id").toInt();
            songIDs.append(songID);
        }
    }

    return songIDs;
}

bool MusicLibrary::insertScanResult(const QStringList &musicFiles){

    if (!m_db.isOpen()) {
        qCritical() << "Database is not open";
        return false;
    }

    QSqlQuery query(m_db);
    
    if (!m_db.transaction()) {
        qCritical() << "Failed to start transaction:" << m_db.lastError().text();
        return false;
    }

    query.prepare("INSERT OR IGNORE INTO MusicsFound (music_path) VALUES (:path)");
    
    for (const QString &filePath : musicFiles) {
        query.bindValue(":path", filePath);
        
        if (!query.exec()) {
            qCritical() << "Failed to insert file:" << filePath 
                       << "Error:" << query.lastError().text();
            m_db.rollback(); 
            return false;
        }
    }

    if (!m_db.commit()) {
        qCritical() << "Commit failed:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    qDebug() << "Inserted" << musicFiles.size() << "records (ignored duplicates)";
    return true;
}

bool MusicLibrary::parseInsertResult()
{

    QString debugTitle = "parseInsertResult";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << "- Database is not open";
        return false;
    }

    QStringList musicFiles = retrieveMusicFiles();
    if (musicFiles.isEmpty()) {
        qWarning() << debugTitle << "- No music files found in database";
        return false;
    }

    // // 读取所有的专辑信息
    // QVector<QSharedPointer<AlbumInfo>> albumInfos;
    // for (auto &musicfilepath : musicFiles){
    //     albumInfos.append(readLocalSongAlbum(musicfilepath))
    // }
     
    // // 读取所有的人物信息
    // QVector<QSharedPointer<CharacterInfo>> characterInfos;
    // for (auto &musicfilepath : musicFiles){
    //     characterInfos.append(readLocalSongCharacter(musicfilepath))
    // }
    for (auto &musicfilepath : musicFiles){
        QSharedPointer<SongInfo> tempSongInfo =  readLocalSong(musicfilepath);

        qDebug() << debugTitle << "- Insert: " << tempSongInfo->title;

        int albumID = insertAlbum(tempSongInfo->album);
        if (albumID == -1) {
            qWarning() << debugTitle << "- Failed to insert album:" << tempSongInfo->album->albumName;
        } else {
            tempSongInfo->album->albumID = albumID;
        }

        for (auto &character : tempSongInfo->characters){
            int characterID = insertCharacter(character);
            if (characterID == -1) {
                qWarning() << debugTitle << "- Failed to insert character:" << character->characterName;
            } else {
                character->characterID = characterID;
            }
        }

        int songID = insertSong(tempSongInfo);
    }

    return true;
}

int MusicLibrary::insertCharacter(QSharedPointer<CharacterInfo> characterInfo){

    QString debugTitle = "insertCharacter";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return false;
    }

    int characterID = characterExists(characterInfo->characterName, characterInfo->foreignName);

    if (characterID > 0){
        return characterID;
    }

    QSqlQuery query(m_db);

    query.prepare("INSERT INTO Characters (character_name, character_foreign_name) "
                  "VALUES (:characterName, :foreignName)");
    query.bindValue(":characterName", characterInfo->characterName);
    query.bindValue(":foreignName", characterInfo->foreignName);

    if (!query.exec()) {
        qWarning() << "Insert character failed:" << query.lastError();
        return -1;
    }

    // 获取新插入的 character_id
    int newCharacterId = query.lastInsertId().toInt();
    qDebug() << "New character inserted with ID:" << newCharacterId;
    return newCharacterId;

}

int MusicLibrary::characterExists(const QString& name, const QString& foreign,  const int overlapID){

    QString debugTitle = "characterExists";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return -1;
    }

    // 检查输入有效性
    if (name.isEmpty() && foreign.isEmpty()) {
        throw std::runtime_error("Character name and foreign name cannot both be empty");
    }

    QSqlQuery query(m_db);

    // 检查角色是否存在
    if (name.isEmpty() && !foreign.isEmpty()){
        query.prepare("SELECT character_id FROM Characters WHERE "
            "character_name ISNULL and character_foreign_name = :foreignName AND "
            "overlap_id = :overlapID"
        );
        // query.bindValue(":characterName", characterName.isEmpty() ? QVariant() : characterName);
        query.bindValue(":foreignName", foreign.isEmpty() ? QVariant() : foreign);
        query.bindValue(":overlapID", overlapID);
    } else if (!name.isEmpty() && foreign.isEmpty() ){
        query.prepare("SELECT character_id FROM Characters WHERE "
            "character_name  = :characterName and character_foreign_name ISNULL AND "
            "overlap_id = :overlapID"
        );
        query.bindValue(":characterName", name.isEmpty() ? QVariant() : name);
        query.bindValue(":overlapID", overlapID);
        // query.bindValue(":foreignName", foreignName.isEmpty() ? QVariant() : foreignName);
    } else if (!name.isEmpty() && !foreign.isEmpty() ){
        query.prepare("SELECT character_id FROM Characters WHERE "
            "character_name = :characterName AND "
            "character_foreign_name = :foreignName AND "
            "overlap_id = :overlapID");
            query.bindValue(":characterName", name.isEmpty() ? QVariant() : name);
            query.bindValue(":foreignName", foreign.isEmpty() ? QVariant() : foreign);
            query.bindValue(":overlapID", overlapID);
    }

    qDebug() << "Executing query:" << query.lastQuery();
    qDebug() << "Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check character existence failed:" << query.lastError();
        return -1;
    }

    if (query.next()){
        qDebug() << debugTitle << " - Get character ID";
        int characterID = query.value("character_id").toInt();
        return characterID;
    } else {
        return -1;
    }
}


int MusicLibrary::insertSong( const QSharedPointer<SongInfo> songInfo){

    QString debugTitle = "insertSong";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return false;
    }

    int songID = songExists(songInfo->filePath);

    if (songID > 0){
        return songID;
    }

    QSqlQuery query(m_db);

    qDebug() << debugTitle << " - Insert song:" << songInfo->title;

    // 歌曲名
    QString title = songInfo->title;

    // first artist
    QString first_artist = songInfo->artists.isEmpty() ? "Unknown" : songInfo->artists.first();

    // 时长
    int durations = songInfo->durations;

    // 文件大小
    int file_size = songInfo->fileSize;

    // 文件路径
    QString file_path = songInfo->filePath;

    // 专辑ID
    int album_id = songInfo->album->albumID;

    // 曲目次序
    int track_number = songInfo->trackNumber;
    int disc_number = songInfo->discNumber;
    int total_track_number = songInfo->totalTracks;
    int total_disc_number = songInfo->totalDiscs;

    // 是否喜爱
    bool is_favorite = songInfo->isFavorite;

    // 是否现场版
    bool is_live = songInfo->isLive;

    // 是否单曲
    bool is_single = songInfo->isSingle;

    // 是否翻唱
    bool is_cover = songInfo->isCover;

    // 是否串烧
    bool is_mashup = songInfo->isMashup;

    // 现场演出
    QString live_event = songInfo->liveEvent;
    QString live_event_count = songInfo->liveEventCount;

    // 发布时间
    // 原始发布时间
    int ori_release_year = songInfo->originalReleaseDate.year;
    int ori_release_month = songInfo->originalReleaseDate.month;
    int ori_release_day = songInfo->originalReleaseDate.day;
    int ori_release_level = songInfo->originalReleaseDate.level;

    // 发布时间
    int release_year = songInfo->releaseDate.year;
    int release_month = songInfo->releaseDate.month;
    int release_day = songInfo->releaseDate.day;
    int release_level = songInfo->releaseDate.level;

    // 添加新歌曲

    query.prepare("INSERT INTO Songs ("
        "title, durations, first_artist, file_size, file_path, album_id, track_number, disc_number, "
        "total_track_number, total_disc_number, is_favorite, is_live, is_single, live_event,"
        "live_event_count, is_cover, is_mashup, ori_release_year, ori_release_month, "
        "ori_release_day, ori_release_level, release_year, release_month, release_day, release_level"
        ") VALUES ("
        ":title, :durations, :first_artist, :file_size, :file_path, :album_id, :track_number, :disc_number, "
        ":total_track_number, :total_disc_number, :is_favorite, :is_live, :is_single, :live_event,"
        ":live_event_count, :is_cover, :is_mashup, :ori_release_year, :ori_release_month, "
        ":ori_release_day, :ori_release_level, :release_year, :release_month, :release_day, :release_level"
        ")");
    query.bindValue(":title", title);
    query.bindValue(":durations", durations);
    query.bindValue(":first_artist", first_artist);
    query.bindValue(":file_size", file_size);
    query.bindValue(":file_path", file_path);
    query.bindValue(":album_id", album_id);
    query.bindValue(":track_number", track_number);
    query.bindValue(":disc_number", disc_number);
    query.bindValue(":total_track_number", total_track_number);
    query.bindValue(":total_disc_number", total_disc_number);
    query.bindValue(":is_favorite", is_favorite);
    query.bindValue(":is_live", is_live);
    query.bindValue(":is_single", is_single);
    query.bindValue(":live_event", live_event); 
    query.bindValue(":live_event_count", live_event_count);
    query.bindValue(":is_cover", is_cover);
    query.bindValue(":is_mashup", is_mashup);
    query.bindValue(":ori_release_year", ori_release_year);
    query.bindValue(":ori_release_month", ori_release_month);
    query.bindValue(":ori_release_day", ori_release_day);
    query.bindValue(":ori_release_level", ori_release_level);
    query.bindValue(":release_year", release_year); 
    query.bindValue(":release_month", release_month);
    query.bindValue(":release_day", release_day);
    query.bindValue(":release_level", release_level);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        if (query.lastError().nativeErrorCode() == "2067") { // SQLite 的唯一性错误代码
            qDebug() << debugTitle << " - Song already exists, skipping insertion.";
            // m_db.rollback();
            return false;
        } else {
            qWarning() << debugTitle << " - Insert song failed:" << query.lastError();
            // m_db.rollback();
            return false;
        }
    }

    int newSongID = query.lastInsertId().toInt();
    qDebug() << debugTitle << " - New song inserted:" << newSongID;

    // if (!m_db.commit()) {
    //     qWarning() << debugTitle << " - Commit transaction failed:" << m_db.lastError();
    //     return false;
    // }

    // 处理角色关联
    foreach (const auto &character, songInfo->characters) {
        int characterID = character->characterID;
        QString role = character->role;
        int r1 = pairSongCharacter(newSongID, characterID, role);
    }

    // 处理专辑歌曲
    int r2  = pairAlbumSong(album_id, newSongID);

    
    // 处理流派
    // foreach (const QString &genre, songInfo->genres) {
    //     int r3 = pairSongGenre(newSongID, genre);
    // }

    // 处理语言
    // foreach (const QString &language, songInfo->languages) {
    //     int r4 = pairSongLanguage(newSongID, language);
    // }
    return newSongID;
    // return true
}

int MusicLibrary::songExists(const QString &path){

    QString debugTitle = "songExists";

    QVector<int> tempIDs = searchSong("filePath", path);

    if (tempIDs.isEmpty()){
        return -1;
    }
    int songID =tempIDs.first();

    return songID;
}


QSharedPointer<SongInfo> MusicLibrary::readLocalSong(const QString &filePath){

    QString debugTitle = "readLocalSong";
    QSharedPointer<SongInfo> songInfo(new SongInfo);

    qDebug() << debugTitle << " - Read music file AlbumInfo:" << filePath;
    QSharedPointer<AlbumInfo> album = readLocalSongAlbum(filePath);
    qDebug() << debugTitle << " - Read music file CharacterInfo:" << filePath;
    QVector<QSharedPointer<CharacterInfo>> characters = readLocalSongCharacter(filePath);

    TagLib::FileRef file(filePath.toStdString().c_str());

    if(file.isNull() || !file.tag()) {
        qWarning() << debugTitle << " - Read music file tag failed:" << filePath;
        return QSharedPointer<SongInfo>();
    }
    TagLib::Tag* tag = file.tag();
    TagLib::PropertyMap props = file.file()->properties();
    // 标题
    songInfo->title = QString::fromStdString(tag->title().toCString(true));
    // 专辑ID
    // song->albumID = album->albumID;
    // 文件信息
    // 时长
    songInfo->durations = file.audioProperties()->lengthInSeconds();
    // 文件大小
    songInfo->fileSize = file.file()->length();
    // 文件路径
    songInfo->filePath = filePath;
    
    // 歌手
    // 后期改为从characters中获取
    songInfo->artists = splitString(QString::fromStdString(tag->artist().toCString(true)));

    // 碟片信息
    // 碟片号
    songInfo->discNumber = props.value("DISCNUMBER").toString().toInt();
    songInfo->totalDiscs = props.value("TOTALDISCS").toString().toInt();
    
    // 曲目号
    songInfo->trackNumber = props.value("TRACKNUMBER").toString().toInt();
    songInfo->totalTracks = props.value("TOTALTRACKS").toString().toInt();
    

    // 是否喜爱
    // FAVORITE、LOVE RATING、LOVE任意一个标签中有值则为喜爱
    songInfo->isFavorite = !props["FAVORITE"].isEmpty() || !props["LOVERATING"].isEmpty() || !props["LOVE"].isEmpty();

    // 是否现场
    // LIVE标签有值则为现场
    songInfo->isLive = !props["LIVE"].isEmpty();

    // 是否单曲
    // SINGLE标签有值则为单曲
    songInfo->isSingle = !props["SINGLE"].isEmpty();
    

    // 是否串烧
    // MASHUP标签有值则为串烧
    songInfo->isMashup = !props["MASHUP"].isEmpty();

    // 是否翻唱
    // COVER标签有值则为翻唱
    songInfo->isCover = !props["COVER"].isEmpty();
    
    
    // Date
    // 发行时间
    unsigned int year = tag->year();
    if (year > 0) {
        songInfo->releaseDate = DateInfo(static_cast<int>(year), 1,1,1);
    } 
    if (!props["RDATE"].isEmpty()) {
        // 从RDATE中读取时间
        QString dateString = QString::fromStdString(props["RDATE"].toString().toCString(true));
        songInfo->releaseDate = formatDate(dateString);  
    }
    
    // 原版发行时间
    // 从ORDATE中读取时间
    if (!props["ORDATE"].isEmpty()) {
        QString dateString = QString::fromStdString(props["ORDATE"].toString().toCString(true));
        songInfo->originalReleaseDate = formatDate(dateString);
    }
    
    songInfo->characters = characters;
    songInfo->album = album;

    // 语言
    songInfo->languages = splitString(QString::fromStdString(props["LANGUAGE"].toString().toCString(true)));

    // 流派
    songInfo->genres = splitString(QString::fromStdString(tag->genre().toCString(true)));

    qDebug() << "readSongInfo -" 
        << "Title:" << songInfo->title
         << ", albumID:" << songInfo->albumID
         << ", duration:" << songInfo->durations
         << ", fileSize:" << songInfo->fileSize
         << ", filePath:" << songInfo->filePath
         << ", discNumber:" << songInfo->discNumber
         << ", totalDiscs:" << songInfo->totalDiscs
         << ", trackNumber:" << songInfo->trackNumber
         << ", totalTracks:" << songInfo->totalTracks
         << ", isFavorite:" << songInfo->isFavorite
         << ", isLive:" << songInfo->isLive
         << ", isSingle:" << songInfo->isSingle
         << ", isMashup:" << songInfo->isMashup
         << ", isCover:" << songInfo->isCover
         << ", releaseDate:" << songInfo->releaseDate.toString()
         << ", originalReleaseDate:" << songInfo->originalReleaseDate.toString();

    return songInfo;
}


QSharedPointer<SongInfo> MusicLibrary::getSongInfobyID(const int songID) {

    QString debugTitle = "getSongInfobyID";

    if (songCache.contains(songID)) {
        qDebug() << debugTitle << " - Cache hit for ID" << songID;
        return songCache.value(songID);
    }

    QSharedPointer<SongInfo> songInfo(new SongInfo);

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QSharedPointer<SongInfo>();
    }

    QSqlQuery query(m_db);
    qDebug() << debugTitle << " - query songID:" << songID;

    query.prepare("SELECT "
        "song_id, title, durations, first_artist, file_size, file_path, album_id, "
        "track_number, disc_number, total_track_number, total_disc_number, "
        "is_favorite, is_live, is_single, live_event, live_event_count, is_cover, is_mashup, "
        "ori_release_year, ori_release_month,ori_release_day,ori_release_level, "
        "release_year, release_month, release_day, release_level, created_at, modified_at "
        "FROM Songs WHERE song_id = :songID");
    query.bindValue(":songID", songID);
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check song existence failed:" << query.lastError();
        m_db.rollback();
        return QSharedPointer<SongInfo>();
    }

    if (!query.next()){
        qWarning() << debugTitle << " - No song found with ID: " << songID;
        return QSharedPointer<SongInfo>();
    }

    songInfo->songID = songID;
    songInfo->title = query.value("title").toString();
    songInfo->durations = query.value("durations").toInt();
    songInfo->fileSize = query.value("file_size").toInt();
    songInfo->filePath = query.value("file_path").toString();
    songInfo->albumID = query.value("album_id").toInt();
    songInfo->trackNumber = query.value("track_number").toInt();
    songInfo->discNumber = query.value("disc_number").toInt();
    songInfo->totalTracks = query.value("total_track_number").toInt();
    songInfo->totalDiscs = query.value("total_disc_number").toInt();
    songInfo->isFavorite = query.value("is_favorite").toBool();
    songInfo->isLive = query.value("is_live").toBool();
    songInfo->isSingle = query.value("is_single").toBool();
    songInfo->liveEvent = query.value("live_event").toString();
    songInfo->liveEventCount = query.value("live_event_count").toString();
    songInfo->isCover = query.value("is_cover").toBool();
    songInfo->isMashup = query.value("is_mashup").toBool();

    // 处理原始发布日期
    songInfo->originalReleaseDate = {
        query.value("ori_release_year").toInt(), 
        query.value("ori_release_month").toInt(), 
        query.value("ori_release_day").toInt(),
        query.value("ori_release_level").toInt()
    };

    // 处理发布日期
    songInfo->releaseDate = {
        query.value("release_year").toInt(), 
        query.value("release_month").toInt(), 
        query.value("release_day").toInt(),
        query.value("release_level").toInt()
    };

    // 人物
    songInfo->characters = searchCharacterbySongID(songID);
    songInfo->artists = songInfo->getCharacters("Primary Artist");

    // 流派
    songInfo->genres = {};
    qDebug() << debugTitle << " - genres";
    // 语言
    songInfo->languages = {};

    // 专辑信息
    QSharedPointer<AlbumInfo> albumInfo = getAlbumInfobyID(songInfo->albumID);
    songInfo->albumName = albumInfo->albumName;
    qDebug() << debugTitle << " - languages";

    return songInfo;

}

QVector<int> MusicLibrary::searchSong(const QString &key, const QVariant &value){

    QString debugTitle = "searchSong";
    QVector<int>songIDs;

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QVector<int>();
    }

    QSqlQuery query(m_db);

    if (value.canConvert<QString>()) {
        QStringList keyList = {"title", "first_artist", "file_path"};
        if (!keyList.contains(key)){
            return QVector<int>();
        }
        QString strValue = value.toString();

        qDebug() << "Searching by key:" << key << ", Value: " << strValue;
        
        query.prepare(
            "SELECT song_id FROM Songs WHERE :key = :value"
        );
        query.bindValue(":key", key);
        query.bindValue(":value", strValue);

    } 
    else if (value.canConvert<int>()) {
        QStringList keyList = {"durations", "album_id", "file_path", "file_size"};
        if (!keyList.contains(key)){
            return QVector<int>();
        }
        int intValue = value.toInt();

        qDebug() << "Searching by key:" << key << ", Value: " << intValue;
        
        query.prepare(
            "SELECT song_id FROM Songs WHERE :key = :value"
        );
        query.bindValue(":key", key);
        query.bindValue(":value", intValue);

    }
    else if (value.canConvert<bool>()) {
        QStringList keyList = {"is_favorite", "is_live", "is_single","is_cover", "is_mashup"};
        if (!keyList.contains(key)){
            return QVector<int>();
        }
        int boolValue = value.toBool();

        qDebug() << "Searching by key:" << key << ", Value: " << boolValue;
        
        query.prepare(
            "SELECT song_id FROM Songs WHERE :key = :value"
        );
        query.bindValue(":key", key);
        query.bindValue(":value", boolValue);

    }
    else {
        qWarning() << "Unsupported value type:" << value.typeName();
        return QVector<int>();
    }

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qCritical() << debugTitle << " - Query failed:" << query.lastError().text();
        return QVector<int>();
    }

    while(query.next()){
        int existingSongID = query.value(0).toInt();
        qDebug() << debugTitle << " - Song:"  << existingSongID;
        songIDs.append(existingSongID);
    }

    return songIDs;
}

QSharedPointer<AlbumInfo> MusicLibrary::readLocalSongAlbum(const QString &path) {

    QString debugTitle = "readLocalSongAlbum";

    TagLib::FileRef file(path.toStdString().c_str());

    if(file.isNull() || !file.tag()) {
        qWarning() << debugTitle << " - Read music file tag failed: " << path;
        return QSharedPointer<AlbumInfo>();
    }

    TagLib::Tag* tag = file.tag();
    TagLib::PropertyMap props = file.file()->properties();
    // 专辑名
    qDebug() << debugTitle << " - Start get albuminfo" << QString::fromStdString(tag->album().toCString(true));
    QSharedPointer<AlbumInfo> album(new AlbumInfo(QString::fromStdString(tag->album().toCString(true))));
    
    // album->albumName = QString::fromStdString(tag->album().toCString(true));
    qDebug() << debugTitle << " - albumName: " << album->albumName;
    // 专辑演出者
    album->albumArtists = splitString(QString::fromStdString(props["ALBUMARTIST"].toString().toCString(true)));
    // 流派
    album->genres = splitString(QString::fromStdString(tag->genre().toCString(true)));

    // 发行方
    album->publishers = splitString(QString::fromStdString(props["PUBLISHER"].toString().toCString(true)));

    // 专辑版本
    album->albumVersion = QString::fromStdString(props["ALBUMVERSION"].toString().toCString(true));

    // 专辑封面

    // 发行时间
    unsigned int year = tag->year();
    if (year > 0) {
        album->albumReleaseTime = {static_cast<int>(year),1,1,1};
    } 
    if (!props["RDATE"].isEmpty()) {
        // 从RDATE中读取时间
        QString dateString = QString::fromStdString(props["RDATE"].toString().toCString(true));
        album->albumReleaseTime = formatDate(dateString);  
    }

    // 国家
    album->country = QString::fromStdString(props["COUNTRY"].toString().toCString(true));

    // 总碟数
    if (!props["TOTALDISCS"].isEmpty()) {
        QString discStr = QString::fromStdString(
            props["TOTALDISCS"].front().toCString(true)
        );
        album->totalDiscs = discStr.toInt();
    } else {
        album->totalDiscs = 0;  // 默认值
    }

    // 语言
    album->languages = splitString(QString::fromStdString(props["LANGUAGE"].toString().toCString(true)));

    // 现场版
    album->liveEvent = QString::fromStdString(props["LIVEEVENT"].toString().toCString(true));
    album->liveEventCount = QString::fromStdString(props["LIVEEVENTCOUNT"].toString().toCString(true));
    
    return album;
}

int MusicLibrary::insertAlbum( const QSharedPointer<AlbumInfo> albumInfo) {

    QString debugTitle = "insertAlbum";

    if (!m_db.isOpen()) {
        qCritical() << "Database is not open";
        return -1;
    }

    QSqlQuery query(m_db);

    // 专辑名
    QString albumName = albumInfo->albumName;

    // 专辑演出者
    QString albumFirstArtist = albumInfo->albumArtists.isEmpty() ? "Unknown" : albumInfo->albumArtists.first();
    
    // 专辑评分
    int albumScore = albumInfo->albumScore;
    

    // 专辑版本
    QString albumVersion = albumInfo->albumVersion;

    // 发行方，转换为以逗号分隔的字符串
    QString publisherStr = albumInfo->publishers.join(", ");
    

    // 流派和语言

    // 专辑发布日期，分别以int的形式存储年月日，使用level区分
    int albumReleaseYear = albumInfo->albumReleaseTime.year;
    int albumReleaseMonth = albumInfo->albumReleaseTime.month;
    int albumReleaseDay = albumInfo->albumReleaseTime.day;
    int albumReleaseLevel = albumInfo->albumReleaseTime.level;

    // 国家
    QString countryStr = albumInfo->country;

    // 碟数
    int totalDiscs = albumInfo->totalDiscs;
    
    // 演出信息
    QString liveEvent = albumInfo->liveEvent;
    QString liveEventCount = albumInfo->liveEventCount;
    

    // 检查专辑是否存在
    int albumID = albumExists(albumName, albumFirstArtist, albumReleaseYear);

    if (albumID > 0){
        return albumID;
    }

    qDebug() << "ensureAlbumExists --  Name:" << albumName
            << ", First Artist:" << albumFirstArtist
            << ", Score:" << albumScore
            << ", Version:" << albumVersion
            << ", Publisher:" << publisherStr
            << ", Release Time:" << albumReleaseYear << "-" << albumReleaseMonth << "-" << albumReleaseDay << " Level:" << albumReleaseLevel
            << ", Country:" << countryStr
            << ", Total Discs:" << totalDiscs
            << ", Live Event:" << liveEvent << " Count:" << liveEventCount;

    // 添加新专辑
    query.prepare("INSERT INTO Albums ("
        "album_name, album_first_artist, publisher, album_score, album_version, "
        "original_release_year, original_release_month, original_release_day, original_release_level, "
        "album_release_year, album_release_month, album_release_day, album_release_level, "
        "country, genres, total_discs, "
        "cover_path, languages, live_event, live_event_count)"
        "VALUES ("
        ":albumName, :albumFirstArtist, :publisher, :albumScore, :albumVersion, "
        ":originalReleaseYear, :originalReleaseMonth, :originalReleaseDay, :originalReleaseLevel, "
        ":albumReleaseYear, :albumReleaseMonth, :albumReleaseDay, :albumReleaseLevel, "
        ":country, :genres, :totalDiscs, "
        ":coverPath, :languages, :liveEvent, :liveEventCount)");
    query.bindValue(":albumName", albumName);
    query.bindValue(":albumFirstArtist", albumFirstArtist);
    query.bindValue(":publisher", publisherStr);
    query.bindValue(":albumScore", albumScore);
    query.bindValue(":albumVersion", albumVersion);
    query.bindValue(":originalReleaseYear", albumInfo->originalReleaseTime.year);
    query.bindValue(":originalReleaseMonth", albumInfo->originalReleaseTime.month);
    query.bindValue(":originalReleaseDay", albumInfo->originalReleaseTime.day);
    query.bindValue(":originalReleaseLevel", albumInfo->originalReleaseTime.level);
    query.bindValue(":albumReleaseYear", albumReleaseYear);
    query.bindValue(":albumReleaseMonth", albumReleaseMonth);
    query.bindValue(":albumReleaseDay", albumReleaseDay);
    query.bindValue(":albumReleaseLevel", albumReleaseLevel);
    query.bindValue(":country", countryStr);
    query.bindValue(":genres", albumInfo->genres.join(", "));
    query.bindValue(":totalDiscs", totalDiscs);
    query.bindValue(":coverPath", albumInfo->albumCoverPath);
    query.bindValue(":languages", albumInfo->languages.join(", "));
    query.bindValue(":liveEvent", liveEvent);
    query.bindValue(":liveEventCount", liveEventCount);
    
    if (!query.exec()) {
        if (query.lastError().nativeErrorCode() == "2067") { // SQLite 的唯一性错误代码
            qDebug() << "Album already exists, skipping insertion.";
            m_db.rollback();
            return -1;
        } else {
            qWarning() << "Insert album failed:" << query.lastError();
            m_db.rollback();
            return -1;
        }
    }
    
    int newAlbumID = query.lastInsertId().toInt();
    qDebug() << "New album inserted:" << newAlbumID;

    // if (!m_db.commit()) {
    //     qWarning() << "Commit transaction failed:" << m_db.lastError();
    //     return -1;
    // }

    return newAlbumID;

}

int MusicLibrary::albumExists(const QString &albumName, const QString &albumFirstArtist, const int albumReleaseYear) {

    QString debugTitle = "albumExists";

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return -1;
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT album_id FROM Albums WHERE "
        "album_name = :albumName AND "
        "album_first_artist = :albumFirstArtist AND "
        "album_release_year = :albumReleaseYear");
    query.bindValue(":albumName", albumName);
    query.bindValue(":albumFirstArtist", albumFirstArtist);
    query.bindValue(":albumReleaseYear", albumReleaseYear);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check song existence failed:" << query.lastError();
        m_db.rollback();
        return -1;
    }

    if (query.next()) {
        int existingAlbumID = query.value(0).toInt();
        qDebug() << debugTitle << " - Album already exists:" << existingAlbumID;
        return existingAlbumID;
    }

    return -1;
}

QVector<QSharedPointer<SongInfo>> MusicLibrary::getSongInfobyAlbumID(const int albumID){

    QVector<QSharedPointer<SongInfo>> songInfos;
    
    QString debugTitle = "getSongInfobyAlbumID";

    QVector<int> songIDs = searchSong("album_id", albumID);

    if (songIDs.isEmpty()){
        qWarning() << debugTitle << " - Album: " << albumID << " is empty";
        return QVector<QSharedPointer<SongInfo>>();
    }

    for (auto &songID : songIDs){
        songInfos.append(getSongInfobyID(songID));
    }

    return songInfos;
}

QSharedPointer<AlbumInfo> MusicLibrary::getAlbumInfobyID(const int albumID){

    QString debugTitle = "getAlbumInfobyID";
    

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QSharedPointer<AlbumInfo>();
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT * FROM Albums WHERE album_id = :albumID");
    query.bindValue(":albumID", albumID);

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Check album existence failed:" << query.lastError();
        m_db.rollback();
        return QSharedPointer<AlbumInfo>();
    }

    if (!query.next()) {
        qDebug() << debugTitle << " - Album not exists:" << albumID;
        return QSharedPointer<AlbumInfo>();
    }

    qDebug() << debugTitle << " - Album already exists:" << albumID;

    // 专辑名
    QSharedPointer<AlbumInfo> album(new AlbumInfo(query.value("album_name").toString()));
    // album->albumName = query.value("album_name").toString();
    // 专辑演出者
    album->albumArtists = splitString(query.value("album_first_artist").toString());
    // 流派
    album->genres = splitString(query.value("genres").toString());

    // 发行方
    album->publishers = splitString(query.value("publisher").toString());

    // 专辑版本
    album->albumVersion = query.value("album_version").toString();

    // 专辑封面

    // 发行时间
    album->albumReleaseTime = {
        query.value("album_release_year").toInt(),
        query.value("album_release_month").toInt(),
        query.value("album_release_day").toInt(),
        query.value("album_release_level").toInt()
    };
    album->originalReleaseTime = {
        query.value("original_release_year").toInt(),
        query.value("original_release_month").toInt(),
        query.value("original_release_day").toInt(),
        query.value("original_release_level").toInt()
    };

    // 国家
    album->country = query.value("country").toString();

    // 总碟数
    album->totalDiscs = query.value("total_discs").toInt();
    

    // 语言
    album->languages = splitString(query.value("languages").toString());

    // 现场版
    album->liveEvent = query.value("live_event").toString();
    album->liveEventCount = query.value("live_event_count").toString();
    
    return album;
}

QVector<int> MusicLibrary::searchAlbum(const QString &key, const QVariant &value) {

    QString debugTitle = "searchAlbum";
    QVector<int>albumIDs;

    if (!m_db.isOpen()) {
        qCritical() << debugTitle << " - Database is not open";
        return QVector<int>();
    }

    QSqlQuery query(m_db);

    if (value.canConvert<QString>()) {
        QStringList keyList = {"album_name", "album_first_artist", "publisher" , "country", "genres", "cover_path", "live_event", "live_event_count"};
        if (!keyList.contains(key)){
            return QVector<int>();
        }
        QString strValue = value.toString();

        qDebug() << "Searching by key:" << key << ", Value: " << strValue;
        
        query.prepare(
            "SELECT album_id FROM Albums WHERE :key = :value"
        );
        query.bindValue(":key", key);
        query.bindValue(":value", strValue);

    } 
    else if (value.canConvert<int>()) {
        QStringList keyList = {"album_score", "original_release_year","album_release_year","total_discs"};
        if (!keyList.contains(key)){
            return QVector<int>();
        }
        int intValue = value.toInt();

        qDebug() << "Searching by key:" << key << ", Value: " << intValue;
        
        query.prepare(
            "SELECT album_id FROM Albums WHERE :key = :value"
        );
        query.bindValue(":key", key);
        query.bindValue(":value", intValue);

    }
    else {
        qWarning() << "Unsupported value type:" << value.typeName();
        return QVector<int>();
    }

    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qCritical() << debugTitle << " - Query failed:" << query.lastError().text();
        return QVector<int>();
    }

    while(query.next()){
        int existingAlbumID = query.value(0).toInt();
        qDebug() << debugTitle << " - Album:"  << existingAlbumID;
        albumIDs.append(existingAlbumID);
    }

    return albumIDs;
}

QVector<QSharedPointer<CharacterInfo>> MusicLibrary::readLocalSongCharacter(const QString &path){

    QString debugTitle = "readLocalSongCharacter";
    QVector<QSharedPointer<CharacterInfo>>characters;

    TagLib::FileRef file(path.toStdString().c_str());

    if(file.isNull() || !file.tag()) {
        qWarning() << debugTitle << " - Read music file tag failed: " << path;
        return QVector<QSharedPointer<CharacterInfo>>();
    }

    TagLib::Tag* tag = file.tag();
    TagLib::PropertyMap props = file.file()->properties();
    qDebug() << debugTitle << " - MusicTag read";

    // 演出者
    QStringList artists = splitString(QString::fromStdString(tag->artist().toCString(true)));
    for (const QString &artist : artists) {
        qDebug() << debugTitle << " - Found Primary Artist: " << artist;
        characters.append(QSharedPointer<CharacterInfo>::create("Primary Artist", artist, ""));
    }
    // 专辑演出者
    QStringList albumArtists = splitString(QString::fromStdString(props["ALBUMARTIST"].toString().toCString(true)));
    for (const QString &albumArtist : albumArtists) {
        qDebug() << debugTitle << " - Found Album Artist: " << albumArtist;
        characters.append(QSharedPointer<CharacterInfo>::create("Album Artist", albumArtist, ""));
    }
    // 作曲
    QStringList composers = splitString(QString::fromStdString(props["COMPOSER"].toString().toCString(true)));
    for (const QString &composer : composers) {
        qDebug() << debugTitle << " - Found Composer: " << composer;
        characters.append(QSharedPointer<CharacterInfo>::create("Composer", composer, ""));
    }
    // 作词
    QStringList lyricists = splitString(QString::fromStdString(props["LYRICIST"].toString().toCString(true)));
    for (const QString &lyricist : lyricists) {
        qDebug() << debugTitle << " - Found Lyricist: " << lyricists;
        characters.append(QSharedPointer<CharacterInfo>::create("Lyricist", lyricist, ""));
    }
    // 指挥
    QStringList conductors = splitString(QString::fromStdString(props["CONDUCTOR"].toString().toCString(true)));
    for (const QString &conductor : conductors) {
        qDebug() << debugTitle << " - Found Conductor: " << conductors;
        characters.append(QSharedPointer<CharacterInfo>::create("Conductor", conductor, ""));
    }
    
    return characters;
}

bool MusicLibrary::pairSongCharacter(const int songID, const int characterID, const QString &role){
    QString debugTitle = "pairSongCharacter";

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return false;
    }

    QSqlQuery query(m_db);

    query.prepare("INSERT INTO SongCharacters (song_id, character_id, role) VALUES (?, ?, ?)");
    query.bindValue(0,songID); 
    query.bindValue(1,characterID);
    query.bindValue(2,role);
    
    qDebug() << debugTitle << " - Raw SQL:" << query.lastQuery().toUtf8().constData();
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Failed to insert song-character:" << query.lastError();
        m_db.rollback();
        return false;
    } else {
        return true;
    }
}

bool MusicLibrary::pairAlbumCharacter(const int AlbumID, const int characterID, const QString &role) {

    QString debugTitle = "pairAlbumCharacter";

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return false;
    }

    QSqlQuery query(m_db);

    query.prepare("INSERT INTO AlbumCharacters (album_id, character_id, role) VALUES (?, ?, ?)");
    query.bindValue(0,AlbumID); 
    query.bindValue(1,characterID);
    query.bindValue(2,AlbumID);
    
    qDebug() << debugTitle << " - Raw SQL:" << query.lastQuery().toUtf8().constData();
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Failed to insert album-character:" << query.lastError();
        return false;
    } else {
        return true;
    }
}

bool MusicLibrary::pairAlbumSong(const int albumID, const int songID, const int track_number, const int disc_number) {

    QString debugTitle = "pairAlbumSong";

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return false;
    }

    QSqlQuery query(m_db);

    query.prepare("INSERT INTO AlbumSongs (album_id, song_id,track_number , disc_number) VALUES (?, ?, ?, ?)");
    query.bindValue(0,albumID); 
    query.bindValue(1,songID);
    query.bindValue(2,track_number);
    query.bindValue(3,disc_number);
    
    qDebug() << debugTitle << " - Raw SQL:" << query.lastQuery().toUtf8().constData();
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Failed to insert album-song:" << query.lastError();
        return false;
    } else {
        return true;
    }
}

// bool MusicLibrary::pairSongGenre(const int songID, const QString &genre){

//     QString debugTitle = "pairSongGenre";

//     if (!m_db.isOpen()) {
//         qCritical() << debugTitle << " - Database is not open";
//         return -1;
//     }

//     QSqlQuery query(m_db);

//     query.prepare("INSERT INTO SongGenres (song_id, genre) "
//                   "VALUES (:songID, :genre)");
//     query.bindValue(":songID", songID);
//     query.bindValue(":genre", genre);

//     qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
//     qDebug() << debugTitle << " - Bound values:" << query.boundValues();

//     if (!query.exec()) {
//         qWarning() << debugTitle << " - Failed to insert song-genre:" << query.lastError();
//         return false;
//     } else {
//         return true;
//     }
// }

// bool MusicLibrary::pairSongLanguage(const int songID, const QString &language){

//     QString debugTitle = "pairSongGenre";

//     if (!m_db.isOpen()) {
//         qCritical() << debugTitle << " - Database is not open";
//         return -1;
//     }

//     QSqlQuery query(m_db);

//     query.prepare("INSERT INTO SongLanguages (song_id, language) "
//                   "VALUES (:songID, :language)");
//     query.bindValue(":songID", songID);
//     query.bindValue(":genre", language);

//     qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
//     qDebug() << debugTitle << " - Bound values:" << query.boundValues();

//     if (!query.exec()) {
//         qWarning() << debugTitle << " - Failed to insert song-language:" << query.lastError();
//         return false;
//     } else {
//         return true;
//     }
// }

QSharedPointer<CharacterInfo> MusicLibrary::getCharacterInfobyID(const int characterID) {

    QString debugTitle = "getCharacterInfobyID";

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return QSharedPointer<CharacterInfo>();
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT character_id, character_name, character_foreign_name, "
        "portrait_path, overlap_id, created_at, modified_at "
        "FROM Characters WHERE character_id = :characterID");
    
    query.bindValue(":characterID", characterID);
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qWarning() << debugTitle << " - Failed to get character id:" << query.lastError();
        return QSharedPointer<CharacterInfo>();
    }

    return QSharedPointer<CharacterInfo>::create(
        "", 
        query.value("character_name").toString(),
        query.value("character_foreign_name").toString()
    );
}

QVector<QSharedPointer<CharacterInfo>> MusicLibrary::searchCharacterbyAlbumID(const int albumID) {

    QString debugTitle = "searchCharacterbyAlbumID";
    QVector<QSharedPointer<CharacterInfo>> characterInfos;

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return QVector<QSharedPointer<CharacterInfo>>();
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT ac.album_id, ac.character_id, ac.character_name, ac.character_foreign_name, "
        "ac.portrait_path, ac.overlap_id, ac.created_at, ac.modified_at, ac.role "
        "FROM AlbumCharacters ac "
        "INNER JOIN Albums a ON ac.album_id = a.album_id "
        "WHERE a.album_id = :albumID");
    query.bindValue(":albumID", albumID);
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qDebug() << debugTitle << " - Search AlbumCharacters failed:" << query.lastError().text();
        return QVector<QSharedPointer<CharacterInfo>>();
    }

    while (query.next()) {
        QSharedPointer<CharacterInfo> tempCharacterInfo;
        tempCharacterInfo->characterID = query.value("character_id").toInt();
        tempCharacterInfo->characterName = query.value("character_name").toString();
        tempCharacterInfo->foreignName = query.value("character_foreign_name").toString();
        tempCharacterInfo->portrait_path = query.value("portrait_path").toString();
        tempCharacterInfo->overlap_id = query.value("overlap_id").toInt();
        tempCharacterInfo->role = query.value("role").toString();
        tempCharacterInfo->modified = query.value("created_at").toDateTime();
        characterInfos.append(tempCharacterInfo);
    }

    return characterInfos;
}

QVector<QSharedPointer<CharacterInfo>> MusicLibrary::searchCharacterbySongID(const int songID) {

    QString debugTitle = "searchCharacterbySongID";
    QVector<QSharedPointer<CharacterInfo>> characterInfos;

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return QVector<QSharedPointer<CharacterInfo>>();
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT "
              "sc.song_id, "
              "c.character_id, "  
              "c.character_name, "
              "c.character_foreign_name, "
              "c.portrait_path, "
              "c.overlap_id, "
              "c.created_at, "
              "c.modified_at, "
              "sc.role "  
              "FROM SongCharacters sc "
              "INNER JOIN Characters c ON sc.character_id = c.character_id "
              "WHERE sc.song_id = :songID");
    query.bindValue(":songID", songID);
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qDebug() << debugTitle << " - Search SongCharacters failed:" << query.lastError().text();
        return QVector<QSharedPointer<CharacterInfo>>();
    }

    while (query.next()) {

        QString role = query.value("role").toString();
        QString name = query.value("character_name").toString();
        QString foreign = query.value("character_foreign_name").toString();

        QSharedPointer<CharacterInfo> tempCharacterInfo(
            new CharacterInfo(role, name, foreign)
        );
        tempCharacterInfo->characterID = query.value("character_id").toInt();
        tempCharacterInfo->portrait_path = query.value("portrait_path").toString();
        tempCharacterInfo->overlap_id = query.value("overlap_id").toInt();
        tempCharacterInfo->modified = query.value("created_at").toDateTime();

        // QSharedPointer<CharacterInfo> tempCharacterInfo;
        // tempCharacterInfo->characterID = query.value("character_id").toInt();
        // tempCharacterInfo->characterName = query.value("character_name").toString();
        // tempCharacterInfo->foreignName = query.value("character_foreign_name").toString();
        // tempCharacterInfo->portrait_path = query.value("portrait_path").toString();
        // tempCharacterInfo->overlap_id = query.value("overlap_id").toInt();
        // tempCharacterInfo->role = query.value("role").toString();
        // tempCharacterInfo->modified = query.value("created_at").toDateTime();
        characterInfos.append(tempCharacterInfo);
    }

    return characterInfos;
}

QVector<QSharedPointer<SongInfo>> MusicLibrary::searchSongbyCharacterID(const int characterID){

    QString debugTitle = "searchSongbyCharacterID";
    QVector<QSharedPointer<SongInfo>> songInfos;
    QVector<int> songIDs;

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return QVector<QSharedPointer<SongInfo>>();
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT song_id, character_id, role "
        "FROM SongCharacters "
        "WHERE character_id = :characterID");
    query.bindValue(":characterID", characterID);
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qDebug() << debugTitle << " - Search SongCharacters failed:" << query.lastError().text();
        return QVector<QSharedPointer<SongInfo>>();
    }

    while (query.next()) {
        songIDs.append(query.value("song_id").toInt());
        songInfos.append(getSongInfobyID(query.value("song_id").toInt()));
    }

    if (songIDs.isEmpty()){
        return QVector<QSharedPointer<SongInfo>>();
    }

    return songInfos;
}

QVector<QSharedPointer<AlbumInfo>> MusicLibrary::searchAlbumbyCharacterID(const int characterID){

    QString debugTitle = "searchAlbumbyCharacterID";
    QVector<QSharedPointer<AlbumInfo>> albumInfos;
    QVector<int> albumIDs;

    if (!m_db.isOpen()) {
        qCritical() <<  debugTitle << " - Database is not open";
        return QVector<QSharedPointer<AlbumInfo>>();
    }

    QSqlQuery query(m_db);

    query.prepare("SELECT album_id, character_id, role "
        "FROM AlbumCharacters "
        "WHERE character_id = :characterID");
    query.bindValue(":characterID", characterID);
    qDebug() << debugTitle << " - Executing query:" << query.lastQuery();
    qDebug() << debugTitle << " - Bound values:" << query.boundValues();

    if (!query.exec()) {
        qDebug() << debugTitle << " - Search AlbumCharacters failed:" << query.lastError().text();
        return QVector<QSharedPointer<AlbumInfo>>();
    }

    while (query.next()) {
        albumIDs.append(query.value("album_id").toInt());
        albumInfos.append(getAlbumInfobyID(query.value("album_id").toInt()));
    }

    if (albumIDs.isEmpty()){
        return QVector<QSharedPointer<AlbumInfo>>();
    }

    return albumInfos;
}