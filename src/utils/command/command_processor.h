#ifndef COMMAND_PROCESSOR_H
#define COMMAND_PROCESSOR_H

#include <QObject>
#include <QHash>
#include <QString>
#include <memory>

class AbstractCommand;
class IntMusicServer;

class CommandProcessor : public QObject {
    Q_OBJECT
public:
    explicit CommandProcessor(IntMusicServer* window, QObject* parent = nullptr);
    ~CommandProcessor();

    void registerCommand(std::unique_ptr<AbstractCommand> command);
    void process(const QString& inputText);

    QList<AbstractCommand*> getCommands() const;

private:
    IntMusicServer* m_window;
    QHash<QString, AbstractCommand*> m_commands;
};

#endif // COMMAND_PROCESSOR_H