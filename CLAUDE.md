# CLAUDE.md

Discourse 插件：公开「淘专辑」/公共收藏夹。功能与使用见 [README.md](README.md)；HTTP API 设计见 [docs/index.md](docs/index.md)。

**开发在本仓库进行。** Discourse 核心仓只读参照：主键类型以核心的 `db/structure.sql` 为准。

改动 schema 前先读 [docs/11-表结构.md](docs/11-表结构.md) 里的表用途与查询业务，再决定改法。

## 硬规则

1. **每张表都有真主键**。非必要不用自增代理 id。

2. **使用外键**。外键内联 `REFERENCES ... ON DELETE CASCADE/SET NULL`。核心惯例是不建外键，本插件有意偏离。

3. 冗余列由**业务层原子维护，无 DB 触发器**：`collections.topic_count` / `last_topic_added_at` / `subscribers_count`、`collection_topics.has_selected_reply`。`updated_at` 无触发器，由写入方置值。`subscribers_count` 口径 = 该专辑订阅行数 − 当前 owner 行（owner 自动订阅但不计入订阅数）。

4. 共同维护者上限 `collection_max_teamworkers_per_collection`**不计 owner**，按 `is_owner=false` 行计数，设 0 即关闭共同维护。专辑数与维护者两条上限各配一个**豁免角色**设置，命中的用户可在超限后继续创建/加人。另：专辑阅读页每话题**内联返回**的精选回复条数受 `collection_max_selected_replies_per_topic` 约束——这是 **API 展示上限、非数据容量上限**（DB 允许每话题任意多条精选，溢出由前端经翻页端点补查）。

5. **索引**（主键之外仅这些；**每条外键的引用列都有索引**——PG 的 `CASCADE` / `SET NULL` 按引用列对子表删改行，缺索引即外键侧每删一行扫一遍子表）：

   | 表 | 索引 |
   | --- | --- |
   | `collections` | `(created_at)`<br>`(last_topic_added_at DESC NULLS LAST)`<br>`(topic_count)`<br>`(subscribers_count)`<br>`(avatar_upload_id)`<br>`(background_upload_id)` |
   | `collection_topics` | `(topic_id, collection_id)`<br>`(collection_id, created_at, topic_id)` |
   | `collection_teamworkers` | `(collection_id) WHERE is_owner`（**partial unique**，owner 唯一性约束）<br>`(collection_id)`<br>`(user_id, collection_id)` |
   | `collection_topic_selected_replies` | `(collection_id, topic_id, post_id)`<br>`(topic_id)`<br>`(post_id)` |
   | `collection_subscribers` | `(user_id, collection_id)`<br>`(collection_id, created_at)` |
   | `collection_invites` | `(collection_id, created_at)`<br>`(invitee_user_id, created_at)`<br>`(inviter_user_id)` |

   除上述之外无辅助索引。`collections` 四条对应四个 API 排序字段（双向靠正向 / 反向扫描共用一条），其中 `last_topic_added_at` 必须逐字写成 `DESC NULLS LAST`——controller 的两个排序方向都带显式空值位置，btree 默认形态匹配不上。

6. 游客访问由站点设置 `collection_allow_anonymous` 控制，默认关闭（API 拒绝、前端无入口）；开启后游客可见。所有主题/帖子列表服务端按访问者 Guardian 过滤，返回前剔除无权访问项。**例外**：`mine` / `subscribed` / 收件箱（`GET /collections/invites`）/ 订阅者名单（`GET /collections/:id/subscribers`）四个读端点为登录专用，匿名一律 403、不受该设置影响——做法统一为不进 `ensure_read_access`、动作首行 `raise Discourse::NotLoggedIn`（见 [docs/01 §2](docs/01-通用约定.md)）。**其中订阅者名单在登录之上另受站点设置 `collection_subscribers_visibility` 分档收窄**——判定按访问者在该专辑的角色，默认档 `logged_in` = 任意登录用户，即上面这句的口径（取值与逐档判定见 [docs/02 §5](docs/02-路由总表.md)）。

## 开发方式

- 仓库布局照 Discourse 插件惯例：
  - `plugin.rb` + `DiscourseCollection` engine；
  - 后端 `app/{models,services,controllers,serializers,jobs}`；
  - 前端 `assets/javascripts/discourse/{routes,controllers,components,templates,connectors,initializers,lib}` 与 `assets/stylesheets/`；
  - 配置 `config/{settings.yml,routes.rb,locales}`；
  - 迁移 `db/migrate/`；
  - 测试 `spec/`（RSpec）与 `test/javascripts/`（QUnit）。
  - 挂入 `plugins/`（软链）即可迁移/起服，复用其 `bin/rake` / `bin/rspec` / `bin/qunit`。

- 迁移照 `.claude/skills/discourse-migration` 的**结构性**规矩（写完让 DB dump 出 structure.sql、产物不手改、大表 concurrent），但内容用原生 SQL，遵守上面硬规则 1–2。迁移文件名时间戳一律用 **UTC**。

- 前端先加载 `.claude/skills/discourse-frontend-conventions`；UI 用 ui-kit/FormKit/BEM、类型、测试分别照 `.claude/skills/` 下的 `discourse-writing-html-css` / `discourse-writing-typescript` / `discourse-writing-js-tests` / `discourse-writing-rspec-tests`。

- 后端业务逻辑抽 Service::Base（`.claude/skills/discourse-service-authoring`）；站点设置走 `.claude/skills/discourse-site-settings`。

- 字符串用 Sentence case 且可翻译，不做 Proper Case。
