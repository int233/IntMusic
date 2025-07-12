#include "command_processor.h"
#include "abstract_command.h"
#include "intmusic_server.h" 

CommandProcessor::CommandProcessor(IntMusicServer* window, QObject* parent)
    : QObject(parent), m_window(window) {}
CommandProcessor::~CommandProcessor() {
    qDeleteAll(m_commands);
}

void CommandProcessor::registerCommand(std::unique_ptr<AbstractCommand> command) {
    if (!command) return;
    QString name = command->name().toLower();

    m_commands.insert(name, command.release());
}

void CommandProcessor::process(const QString& inputText) {
    QStringList parts = inputText.split(' ', Qt::SkipEmptyParts);
    if (parts.isEmpty()) return;

    QString commandName = parts.takeFirst().toLower();

    AbstractCommand* cmd = m_commands.value(commandName, nullptr);
    
    if (cmd) {
        cmd->execute(parts);
    } else {
        m_window->appendLogMessage(QString("Error: Unknown command '%1'. Type 'help' for a list of commands.").arg(commandName));
    }
}

QList<AbstractCommand*> CommandProcessor::getCommands() const {
    return m_commands.values(); 
}