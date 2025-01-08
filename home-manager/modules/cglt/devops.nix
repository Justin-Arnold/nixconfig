{ cgltPath, pkgs, config, ... }:

{   
    # This defines the root path of the repository and pulls it down.
    home.activation.cloneDevops = {
        after = ["writeBoundary"];
        before = [];
        data = ''
        PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
        DEVOPS_PATH="${cgltPath}/devops"
        if [ ! -d "$DEVOPS_PATH" ]; then
            git clone git@github.com:commongoodlt/devops.git "$DEVOPS_PATH"
        fi
        '';
    };

    home.file."${cgltPath}/devops/docker_satchel/.env".text = ''
        # ##################### #
        # Environment Variables #
        # ##################### #

        # ##################### #
        # APP Config items      #
        # ##################### #
        SATCHEL_APP_DIR=${config.home.homeDirectory}/${cgltPath}/satchel
        SATCHEL_APP_PORT=8002
        SATCHEL_VUE_DEV_SERVER_PORT=6051

        SUITCASE_APP_DIR=${config.home.homeDirectory}/${cgltPath}/suitcase
        SUITCASE_APP_PORT=8003
        SUITCASE_VUE_DEV_SERVER_PORT=6061


        # ##################### #
        # DB Config items       #
        # ##################### #
        SATCHEL_DB_DATA_DIR=${config.home.homeDirectory}/${cgltPath}/satchel-db/data
        SATCHEL_DB_LOAD_DIR=${config.home.homeDirectory}/${cgltPath}/satchel-db/load
        SATCHEL_DB_PORT=3311

        SUITCASE_DB_DATA_DIR=${config.home.homeDirectory}/${cgltPath}/suitcase-db/data
        SUITCASE_DB_LOAD_DIR=${config.home.homeDirectory}/${cgltPath}/suitcase-db/load
        SUITCASE_DB_PORT=3309

        # initial configuration applied at container start for empty DB_DATA_DIR
        MYSQL_ROOT_PASSWORD=Inflection00
        MYSQL_USER=ssaltuser
        MYSQL_PASSWORD=ssaltpassword
        MYSQL_DATABASE=sparklsalt
    ''; # TODO - put the SQL data above in secrets

    programs.zsh.shellAliases = {
        "setup-satchel-db" = ''
            (cd "${cgltPath}/devops/docker_satchel" && \
            docker-compose up -d && \
            docker-compose exec satchel-db bash -c "mysql -u root -h 127.0.0.1 -p sparklsalt < dumpfile.sql && exit")
        '';
        "satchel-up" = ''
            (cd "${cgltPath}/devops/docker_satchel" && \
            docker-compose up -d && \
            docker-compose exec satchel-app /usr/sbin/php-fpm8.3 && \
            cd && \
            cd "${cgltPath}/satchel/vue-cli" && \
            npm i && \
            export NODE_OPTIONS=--openssl-legacy-provider && \
            npm run serve)
        '';
    };
}
