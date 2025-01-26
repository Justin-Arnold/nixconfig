{ cgltPath, pkgs, config, ... }:
{
    # Your existing config here...

    # Add go-task package
    home.packages = [ pkgs.go-task ];

    # Create global Taskfile
    home.file."Taskfile.yml".text = ''
        version: '3'
        
        tasks:
        rebuild:
            cmds:
            - nix run nix-darwin -- switch --flake ~/Code/personal/nixconfig --verbose --show-trace   
        # Add more tasks here
    '';

    # Set environment variable for TASKFILE
    # home.sessionVariables = {
    #     TASKFILE = "${config.home.homeDirectory}/.config/task/Taskfile.yml";
    # };


    # Add a shell alias for `task` to always use the global Taskfile
    programs.zsh.shellAliases = {};
}