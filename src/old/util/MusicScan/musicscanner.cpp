#include "musicscanner.h"
MusicScanner &MusicScanner::instance() {
    static MusicScanner instance;
    return instance;
}

MusicScanner::MusicScanner(QObject *parent)
    : QObject{parent},configManager(ConfigManager::instance())
{
    intSetting = configManager.getSettings();

    // 初始化线程和工作者
    workerThread = new QThread(this);
    worker = new MusicScannerWorker();
    worker->moveToThread(workerThread);

    // 连接工作者信号到MusicScanner信号
    connect(worker, &MusicScannerWorker::scanMusicStarted, this, &MusicScanner::scanMusicStarted);
    connect(worker, &MusicScannerWorker::scanMusicFailed, this, &MusicScanner::scanMusicFailed);
    connect(worker, &MusicScannerWorker::scanMusicFinished, this, &MusicScanner::scanMusicFinished);
    connect(worker, &MusicScannerWorker::scanTagStarted, this, &MusicScanner::scanTagStarted);
    connect(worker, &MusicScannerWorker::scanTagFailed, this, &MusicScanner::scanTagFailed);
    connect(worker, &MusicScannerWorker::scanTagFinished, this, &MusicScanner::scanTagFinished);
    connect(worker, &MusicScannerWorker::musicFileTagRead, this, &MusicScanner::musicFileTagRead);

    // 连接启动扫描的信号
    connect(this, &MusicScanner::startScanRequested, worker, &MusicScannerWorker::doScan);

    // 连接结束扫描的信号
    connect(worker, &MusicScannerWorker::scanMusicFailed, this, [this]() { m_isScanning = false; });
    connect(worker, &MusicScannerWorker::scanMusicFinished, this, [this](int count) { 
        m_isScanning = false; 
        qDebug() << "scanMusicFinished - Total musicfile: " << count;
    });
    connect(worker, &MusicScannerWorker::scanTagFailed, this, [this]() { m_isScanning = false; });
    connect(worker, &MusicScannerWorker::scanTagFinished, this, [this]() { m_isScanning = false; });

    workerThread->start();
}


MusicScanner::~MusicScanner() {

    workerThread->quit();
    workerThread->wait();
    delete worker;
}


void MusicScanner::startScan()
{
    if (m_isScanning) {
        qWarning() << "Scan is already in progress";
        return;
    }
    m_isScanning = true;

    QStringList musicFolders = intSetting->value("Common/MusicFolderPath").toStringList();
    emit startScanRequested(musicFolders, maxFiles);

}
