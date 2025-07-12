#ifndef COMMANDS_HELP_H
#define COMMANDS_HELP_H

#include "abstract_command.h"
#include "intmusic_server.h"
#include "command_processor.h"

class HelpCommand : public AbstractCommand {
public:
    HelpCommand(CommandProcessor* processor, IntMusicServer* window) : m_processor(processor), m_window(window) {}
    void execute(const QStringList& args) override {
        m_window->appendLogMessage("Available commands:");
        for (AbstractCommand* cmd : m_processor->getCommands()) {
            QString paddedName = cmd->name().leftJustified(8, ' ');
            QString formattedLine = QString("  %1 - %2").arg(paddedName, cmd->description());
            m_window->appendLogMessage(formattedLine);
        }
    }
    QString name() const override { return "help"; }
    QString description() const override { return "Shows this help message."; }
private:
    CommandProcessor* m_processor;
    IntMusicServer* m_window;
};

#endif // COMMANDS_HELP_H