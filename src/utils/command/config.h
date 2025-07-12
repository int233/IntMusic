#ifndef COMMAND_CONFIG_H
#define COMMAND_CONFIG_H

#include "abstract_command.h"
#include "intmusic_server.h"
#include "command_processor.h"

#include "config/config_manager.h"
class ConfigManager;

class ConfigCommand : public AbstractCommand {
public:
    explicit ConfigCommand(ConfigManager& config_manager, IntMusicServer* window) : m_configManager(config_manager), m_window(window) {}

    // ConfigCommand(CommandProcessor* processor, IntMusicServer* window) : m_processor(processor), m_window(window) {}

    void execute(const QStringList& args) override;
    QString name() const override { return "config"; }
    QString description() const override { return "Change or show config info."; }

private:
    ConfigManager& m_configManager;
    CommandProcessor* m_processor;
    IntMusicServer* m_window;
};


#endif // COMMAND_CONFIG_H