#include "intmusic_server.h"
#include "command/help.h"
#include "command/config.h"

#include <QVBoxLayout>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QIcon>
#include <QMessageBox>


static IntMusicServer* g_mainWindow = nullptr;

void messageHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg)
{
    Q_UNUSED(context);
    QString formatedMsg = QString("[%1] %2").arg(QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss"), msg);
    if (g_mainWindow) {
        QMetaObject::invokeMethod(g_mainWindow, "appendLogMessage", Qt::QueuedConnection, Q_ARG(QString, formatedMsg));
    }
    fprintf(stderr, "%s\n", formatedMsg.toLocal8Bit().constData());
}

IntMusicServer::IntMusicServer(QWidget *parent) : 
    QMainWindow{parent}, 
    m_configManager(ConfigLoader::FindOrCreateConfigPath()),
    m_commandProcessor(this)
{
    g_mainWindow = this; 
    setupLogging();
    setupUI();
    setupTrayIcon();
    setupCommandProcessor();
    
    connect(commandInput, &QLineEdit::returnPressed, this, &IntMusicServer::onCommandEntered);
    connect(trayIcon, &QSystemTrayIcon::activated, this, &IntMusicServer::onTrayIconActivated);

    // m_commandProcessor.process("help");

}

IntMusicServer::~IntMusicServer()
{
    // g_mainWindow = nullptr;
    // if (trayIcon) {
    //     trayIcon->hide();
    //     delete trayIcon;
    // }
}

void IntMusicServer::setupUI() {
    
    setWindowTitle(tr("IntMusic Server"));
    setGeometry(100, 100, 800, 600);

    QWidget *centralWidget = new QWidget(this);
    setCentralWidget(centralWidget);
    QVBoxLayout *mainLayout = new QVBoxLayout(centralWidget);

    logDisplay = new QTextEdit(this);
    logDisplay->setReadOnly(true); 
    logDisplay->setFont(QFont("Consolas", 10)); 
    logDisplay->append("IntMusicServer 控制台...");
    // setCentralWidget(logDisplay);

    commandInput = new QLineEdit(this);
    commandInput->setPlaceholderText(tr("Enter command..."));
    
    mainLayout->addWidget(logDisplay, 1);
    mainLayout->addWidget(commandInput, 0);

    centralWidget->setLayout(mainLayout);
}

void IntMusicServer::setupTrayIcon()
{

    trayIcon = new QSystemTrayIcon(QIcon(":/resource/intmusic_logo.ico"), this);
    trayIcon->setToolTip("IntMusicServer 正在运行");

    QMenu *trayMenu = new QMenu(this);

    QAction *showHideAction = new QAction("显示服务端", this);
    QAction *openAction = new QAction("打开", this);
    QAction *quitAction = new QAction("退出", this);

    trayMenu->addAction(showHideAction);
    trayMenu->addSeparator();
    trayMenu->addAction(openAction);
    trayMenu->addSeparator();
    trayMenu->addAction(quitAction);

    connect(showHideAction, &QAction::triggered, this, &IntMusicServer::showHideWindow);
    connect(openAction, &QAction::triggered, this, &IntMusicServer::openWindow);
    connect(quitAction, &QAction::triggered, this, &IntMusicServer::quitApplication);

    trayIcon->setContextMenu(trayMenu);

    trayIcon->show();
}

void IntMusicServer::closeEvent(QCloseEvent *event)
{
    event->ignore();
    this->hide();
    trayIcon->showMessage("提示", "IntMusicServer 已最小化", QSystemTrayIcon::Information, 2000);
}

void IntMusicServer::showHideWindow()
{
    if (this->isVisible()) {
        this->hide();
    } else {
        this->show();
        this->activateWindow();
    }
}

void IntMusicServer::openWindow()
{
    if (this->isVisible()) {
        this->hide();
    } else {
        this->show();
        this->activateWindow();
    }
}

void IntMusicServer::quitApplication()
{
    QMessageBox::StandardButton reply;
    reply = QMessageBox::question(this, 
        "确认退出", "确定要退出吗？",
        QMessageBox::Yes | QMessageBox::No
    );

    if (reply == QMessageBox::No) {
        return; 
    }

    qInfo() << "Shutdown initiated by user...";
    
    if (trayIcon) {
        trayIcon->hide();
    }

    qInfo() << "Server thread finished gracefully.";

    QCoreApplication::quit();
}

void IntMusicServer::onTrayIconActivated(QSystemTrayIcon::ActivationReason reason)
{
    switch (reason) {
        case QSystemTrayIcon::Trigger:
            showHideWindow();
            break;
        case QSystemTrayIcon::DoubleClick:
            showHideWindow();
            break;
        case QSystemTrayIcon::Context:
            break;
        default:
            break;
    }
}

void IntMusicServer::setupCommandProcessor()
{
    m_commandProcessor.registerCommand(std::make_unique<HelpCommand>(&m_commandProcessor, this));
    m_commandProcessor.registerCommand(std::make_unique<ConfigCommand>(m_configManager, this));
    // m_commandProcessor.registerCommand(std::make_unique<ClearCommand>(this));
    // m_commandProcessor.registerCommand(std::make_unique<LibraryCommand>(this));

}

void IntMusicServer::onCommandEntered()
{
    QString command = commandInput->text().trimmed();

    if (command.isEmpty()) return;

    appendLogMessage(QString("> %1").arg(command));

    commandInput->clear();

    m_commandProcessor.process(command);
}

void IntMusicServer::ClearLog() {
    if(logDisplay) logDisplay->clear();
}

void IntMusicServer::appendLogMessage(const QString &message)
{
    if (logDisplay) { 
        logDisplay->append(message);
    }
}

void IntMusicServer::setupLogging() {
    qInstallMessageHandler(messageHandler);
}



// load database

// load playlist

// load apiserver
