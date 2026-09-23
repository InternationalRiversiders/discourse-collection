# 专辑头像与背景

创建专辑后，在详情页点「编辑」，再切换到「头像与背景」即可上传、预览、更换和移除。创建者与共同维护者可操作；管理员以及原有设置允许的版主也可管理外观。共同维护者进入「编辑」后直接显示图片设置。普通订阅者、游客不可修改。共同维护者的名称、简介、删除、邀请及转让权限不变。

头像替换列表卡片的默认图标，并出现在详情标题旁；背景图作为列表与详情的封面，居中裁切。无图片的旧专辑保持原样。支持 JPG、PNG、GIF、WebP，上传大小与处理遵循论坛原生限制；建议正方形头像和约 3:1 的背景。关闭编辑窗口不保存，上传期间禁止保存。

`PUT /collections/:id/appearance.json` 接受 `avatar_upload_id` 和/或 `background_upload_id`，只提交改动字段；显式 JSON null 表示移除，省略字段保持原值。返回完整专辑 JSON，新增 `avatar_upload` / `background_upload`（null 或包含 id、url、width、height 的对象）。列表使用相同字段，批量读取上传信息。

图片使用 Discourse 原生 Upload/UppyUpload，类型为公开的 collection_avatar / collection_background。新增图片必须是当前用户上传的公开位图，兼容 UserUpload 去重记录；不能通过猜 ID 引用别人的图片或私密附件。图片类型与权限由服务器再次校验，提交在专辑行锁下原子应用，失败不部分保存。

新增 collections.avatar_upload_id / background_upload_id 外键与索引；上传删除时 SET NULL。保存时同步 UploadReference，避免有效图片被孤儿清理；移除或删除专辑只清理引用，不直接删除共享上传。备份归入论坛正常的数据库和附件备份机制。此次迁移是兼容旧版本的可空新增列，无旧数据改写。

请求回归见 spec/requests/discourse_collection/collections_appearance_spec.rb。运行态隔离验证脚本位于服务器 /opt/discourse-community-test/collection_appearance_test.rb，强制仅允许无网络的专用测试数据库运行。

编辑窗口内的基本信息和图片分别保存，栏目切换保留草稿。如果另一栏仍有修改，保存后窗口保持打开并提示，避免丢弃尚未保存的内容。
