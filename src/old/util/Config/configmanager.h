#ifndef CONFIGMANAGER_H
#define CONFIGMANAGER_H

#include <QObject>
#include <QString>
#include <QDir>
#include <QStandardPaths>
#include <QSettings>
#include <QDirIterator>

class ConfigManager : public QObject
{
    Q_OBJECT
public:
    static ConfigManager& instance();

    // 公共访问方法
    // 获取配置文件
    QSettings* getSettings();
    // 从当前配置文件中获取配置文件路径
    QString configPath() const;
    // 查找配置文件，并返回路径，若不存在配置文件，则调用GetHomeConfigPath()创建新的配置文件
    QString GetConfigPath();
    // 获取用户目录
    QString GetHomePath();
    // 获取音乐目录
    QString GetMusicFolderPath();
    // 获取用户目录中的配置文件路径
    QString GetHomeConfigPath();
    // 获取音乐目录中的配置文件路径
    QString GetMusicFolderConfigPath();
    // 获取用户目录中的Library文件夹路径
    QString GetHomeLibraryPath();
    // 获取音乐目录中的Library文件夹路径
    QString GetMusicFolderLibraryPath();

    // 迁移配置文件
    void migrateConfig(QString oldFolder, QString newFolder);
    // 迁移数据库文件
    // void migrateLibrary(QString oldLibraryFolder, QString newLibraryFolder);

    // 常用配置项快捷访问
    QStringList musicDatabasePaths();
    int setConfig(QString key, QVariant value);

public slots:
    QString SaveConfig(QString configPath = QString(), QSettings* externalSettings = nullptr);

private:
    explicit ConfigManager(QObject *parent = nullptr);
    bool copyDirectory(const QDir &sourceDir, const QDir &targetDir, bool removeSourceAfterCopy);

    const QString configFileName = "intmusic.ini";
    const QString librarySubfix = "intlibrary";

    QSettings* m_settings = nullptr;

signals:
    void settingsChanged();

};

#endif // CONFIGMANAGER_H
