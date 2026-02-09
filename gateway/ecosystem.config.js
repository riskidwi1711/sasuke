module.exports = {
  apps: [
    {
      name: "sasuke-gateway",
      script: "src/server.js",
      cwd: "/home/adminuser/asset-hub/sasuke/gateway",
      log_date_format: "YYYY-MM-DD HH:mm:ss",
      error_file: "./logs/pm2-error.log",
      out_file: "./logs/pm2-out.log",
      merge_logs: true,
      autorestart: true,
      max_restarts: 10,
    },
  ],
};
