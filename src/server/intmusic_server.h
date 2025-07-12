#ifndef INTMUSICSERVER_H
#define INTMUSICSERVER_H

#include <QMainWindow>
#include <QThread>
#include <QLineEdit>
#include <QTextEdit>
#include <QSystemTrayIcon>
#include <QCloseEvent>
#include <QString>
#include <QStringList>
#include <QHash>

#include <functional>

#include "config/config_manager.h"
#include "config/config_loader.h"
#include "command/command_processor.h"

class IntMusicServer : public QMainWindow
{
    Q_OBJECT
public:
    explicit IntMusicServer(QWidget  *parent = nullptr);
    ~IntMusicServer();

    void ClearLog();
    void showLibraryInfo();
    void addLibrary();
    void removeLibrary();

private:
    void setupUI();
    void setupTrayIcon();
    void setupLogging(); 

    // UI 控件
    QTextEdit *logDisplay;
    QLineEdit *commandInput;

    // 系统托盘
    QSystemTrayIcon *trayIcon;

    // 后台服务器
    // QThread serverThread;
    // IntMusicServer *server;

    // 命令管理
    CommandProcessor m_commandProcessor;
    void setupCommandProcessor();
    ConfigManager m_configManager;
    // QHash<QString, std::function<void(const QStringList&)>> m_commands;

    // void setupCommands();

protected:
    void closeEvent(QCloseEvent *event) override;
    // void showEvent(QShowEvent *event) override;

public slots:
    void appendLogMessage(const QString &message);

private slots:
    void onCommandEntered();
    void onTrayIconActivated(QSystemTrayIcon::ActivationReason reason);

    // 托盘菜单
    void showHideWindow();
    void openWindow();
    void quitApplication();


signals:
    void configLoaded();
    void configChanged();
};

#endif // INTMUSICSERVER_H