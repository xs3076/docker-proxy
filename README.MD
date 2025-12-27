

### 第一步：准备阿里云凭证（配置 Secrets）

为了安全，千万**不要**把账号密码直接写在代码里。我们需要把它们存到 GitHub 的“保险箱”里。

1. 打开你的 **GitHub 仓库**页面。
2. 点击顶部菜单栏的 **`Settings` (设置)**。
3. 在左侧侧边栏找到 **`Secrets and variables`** -> 点击 **`Actions`**。
4. 点击右上角的绿色按钮 **`New repository secret`**。
5. 依次添加以下 3 个变量（名称必须大写）：

| Name (变量名) | Secret (变量值) | 说明 |
| --- | --- | --- |
| `ALIYUN_USERNAME` | `你的阿里云用户名` | 通常是淘宝号或邮箱，建议去ACR控制台“访问凭证”查看 |
| `ALIYUN_PASSWORD` | `你的ACR固定密码` | **注意：** 是容器镜像服务的**固定密码**，不是登录官网的密码 |
| `ALIYUN_REGISTRY` | `registry.cn-shanghai.aliyuncs.com` | 你之前提到的上海节点（如果是杭州请自行修改） |

---

### 第二步：创建 Workflow 文件

1. 在你的 GitHub 仓库中，点击 **`Actions`** 选项卡。
2. 点击 **`New workflow`** -> 选择 **`set up a workflow yourself`** (或者直接在代码库创建文件)。
3. 文件路径填写为：`.github/workflows/sync-image.yml`
4. 复制并粘贴以下代码（**只需修改最下方的镜像列表即可**）：

```yaml
name: Sync Images to Aliyun
# 触发条件：手动触发 (点击 Run workflow 按钮)
on: 
  workflow_dispatch:
    inputs:
      # 这里允许你手动输入镜像名，如果不输则用默认的
      image_name:
        description: 'Image name to sync (e.g., redis:latest)'
        required: false
        default: 'all' 

jobs:
  sync-images:
    runs-on: ubuntu-latest
    steps:
      - name: Install Skopeo
        # GitHub 的 ubuntu 环境里通常自带 skopeo，防止万一我们可以装一下
        run: |
          sudo apt-get update
          sudo apt-get -y install skopeo

      - name: Login to Aliyun ACR
        # 使用我们在第一步配置的 Secrets 登录
        run: |
          skopeo login -u "${{ secrets.ALIYUN_USERNAME }}" \
                       -p "${{ secrets.ALIYUN_PASSWORD }}" \
                       ${{ secrets.ALIYUN_REGISTRY }}

      - name: Sync Images
        run: |
          # 定义你要搬运的镜像映射关系
          # 格式：原镜像地址 目标镜像地址
          # 注意：请把下面的 songxuan 换成你自己在上海实际创建的命名空间！
          
          declare -A images
          images=(
            ["docker.io/library/redis:latest"]="songxuan/redis:latest"
            ["docker.io/library/mysql:8.0"]="songxuan/mysql:8.0"
            ["docker.io/library/nginx:alpine"]="songxuan/nginx:alpine"
          )

          # 如果你在运行界面输入了特定镜像，只同步那一个
          INPUT_IMAGE="${{ github.event.inputs.image_name }}"
          
          if [ "$INPUT_IMAGE" != "all" ] && [ -n "$INPUT_IMAGE" ]; then
             echo "🚀 单独同步: $INPUT_IMAGE"
             skopeo copy --all docker://$INPUT_IMAGE docker://${{ secrets.ALIYUN_REGISTRY }}/songxuan/${INPUT_IMAGE##*/}
             exit 0
          fi

          # 否则循环同步上面列表里的所有镜像
          for src in "${!images[@]}"; do
            dest="${images[$src]}"
            echo "----------------------------------------------------"
            echo "🚀 开始同步: $src -> ${{ secrets.ALIYUN_REGISTRY }}/$dest"
            
            skopeo copy --all \
              docker://$src \
              docker://${{ secrets.ALIYUN_REGISTRY }}/$dest
              
            echo "✅ 同步完成"
          done

```

5. 点击右上角的 **`Commit changes`** 保存文件。

---

### 第三步：开始运行（享受自动搬运）

1. 点击仓库顶部的 **`Actions`** 选项卡。
2. 在左侧列表点击我们刚创建的 **`Sync Images to Aliyun`**。
3. 点击右侧的 **`Run workflow`** 按钮。
* *(可选)* 你可以在弹出的框里输入 `mongo:latest` 来临时搬运一个不在列表里的镜像。
* 如果不输入，直接点击绿色的 **`Run workflow`**，它就会搬运代码里写好的 Redis、MySQL 和 Nginx。


4. 等待几十秒（通常非常快），当图标变成绿色对勾 ✅，说明搬运成功！

### 为什么这样做最爽？

1. **极速：** GitHub 的服务器在美国，拉取 Docker Hub 速度是千兆级的，推送到阿里云通常也很快。
2. **多架构：** `skopeo copy --all` 保证了你不管是用 Mac M1 还是 Windows 拉取，都能得到正确的 CPU 架构版本。
3. **零依赖：** 你关掉电脑睡觉，GitHub 还在云端帮你搬砖。

### ⚠️ 重要提示

代码里的 `songxuan` 需要替换成你在**阿里云上海区实际创建的命名空间**。如果还没创建，记得先去阿里云控制台创建一个，否则 Action 会报错 `denied`。