# 专辑默认排序与卡片布局

专辑阅读页的创建者、共同维护者，以及拥有专辑管理权限的管理员，可以在排序栏选择收录时间、话题创建时间或最后回复时间，调整升降序后点击「设为默认」。排序与方向作为一组保存，仅影响当前专辑。普通读者仍可临时切换排序；重新进入专辑时采用维护者设置。现有专辑默认保持收录时间倒序。

`PUT /collections/:id/reading_defaults.json`，请求必须同时提供 `default_topic_sort`（`added_at`、`topic_created_at`、`topic_bumped_at`）与 `default_topic_order`（`asc`、`desc`）。返回完整专辑，含上述两字段。未授权 403，无效组合 422。此权限不扩大共同维护者修改专辑名、简介或删除专辑的权限。

`GET /collections/:id/topics.json` 未指定 sort/order 的字段分别采用专辑默认值；显式 sort/order 优先。访问权限过滤、同方向话题 ID 并列排序及分页规则保持原样。字段没有新索引需求。

所有淘专辑卡片网格（包括用户页及作者专辑弹窗）使用自适应高度的两列排布，保留 DOM 和阅读顺序。图片加载、窗口变化、追加卡片会重排；移动端回到单列。缺少 ResizeObserver/MutationObserver 的浏览器退回普通自然高度网格。
