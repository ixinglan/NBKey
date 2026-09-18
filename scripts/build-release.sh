#!/usr/bin/env bash
#
# 打包 NBKey 的发布产物：构建 → 签名 → （可选）公证 → 生成 DMG。
#
# 为什么把这段写成脚本而不是全塞进 workflow YAML：
#   **本地与 CI 必须跑同一份流程**。YAML 里的脚本没法在本地执行，于是"CI 里跑通的"
#   和"我本地验过的"就变成两套东西，出问题时无法复现。抽成脚本后，
#   本地 `scripts/build-release.sh 1.0.0` 与 CI 走的是**逐行相同**的代码。
#
# 用法：
#   scripts/build-release.sh <版本号> [输出目录]
#   例：scripts/build-release.sh 1.0.0 ./dist
#
# 环境变量（全部可选，各有合理默认）：
#   SIGN_IDENTITY      签名身份。留空/- → ad-hoc 签名（任何人可构建，但用户首次打开需去隔离）
#                      也可以是证书全名或 SHA，例：
#                      "Developer ID Application: jianqiang zhao (3RW8JYPKDG)"
#   BUILD_NUMBER       CFBundleVersion，默认 1
#   ARCHS              默认 "arm64 x86_64"（通用二进制）
#   OUT_DIR            默认 <仓库>/dist
#   APPLE_ID / APPLE_APP_PASSWORD / APPLE_TEAM_ID
#                      有这三项则对产物做公证（notarize）；缺任一项则跳过公证
#   APPLE_API_KEY_PATH / APPLE_API_KEY_ID / APPLE_API_ISSUER_ID
#                      App Store Connect API Key 方式的公证凭据（优先于上面那组）
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 参数与路径
# ---------------------------------------------------------------------------

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "用法: $0 <版本号> [输出目录]" >&2
    echo "例:   $0 1.0.0 ./dist" >&2
    exit 64
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${2:-$REPO_ROOT/dist}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

PROJECT="$REPO_ROOT/KeyLayer/KeyLayer.xcodeproj"
BUILD_DIR="$REPO_ROOT/KeyLayer/build/Release"
APP="$BUILD_DIR/NBKey.app"
ENTITLEMENTS="$REPO_ROOT/KeyLayer/KeyLayer/NBKey.entitlements"
DMG_NAME="NBKey-$VERSION.dmg"
DMG="$OUT_DIR/$DMG_NAME"

# 是不是真的在签名（而不是 ad-hoc）。ad-hoc 没有证书，做不了公证。
if [ "$SIGN_IDENTITY" = "-" ] || [ -z "$SIGN_IDENTITY" ]; then
    IS_ADHOC=1
else
    IS_ADHOC=0
fi

step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
fail()  { printf '\n\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

# 公证凭据齐不齐（两种方式取其一）。
can_notarize() {
    [ "$IS_ADHOC" = "0" ] || return 1
    if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
        return 0
    fi
    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        return 0
    fi
    return 1
}

notarize() {  # $1 = 待公证文件（.zip 或 .dmg）
    if [ -n "${APPLE_API_KEY_PATH:-}" ]; then
        xcrun notarytool submit "$1" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" \
            --wait --timeout 40m
    else
        xcrun notarytool submit "$1" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait --timeout 40m
    fi
}

mkdir -p "$OUT_DIR"
rm -f "$DMG" "$DMG.sha256"

echo "NBKey 发布流水线"
info "版本号     : $VERSION (build $BUILD_NUMBER)"
info "架构       : $ARCHS"
info "签名身份   : $SIGN_IDENTITY"
info "输出目录   : $OUT_DIR"
info "公证       : $(can_notarize && echo '会执行' || echo '跳过（无凭据或 ad-hoc 签名）')"

# ---------------------------------------------------------------------------
# 1. 构建
# ---------------------------------------------------------------------------

step "1/7 构建（Release, $ARCHS）"

# 先删掉旧产物。不删的话，万一这次构建失败、而上次的 app 还躺在原地，
# 后面的步骤会**拿旧包继续往下走**，最终发布一个"看起来成功"的过期版本。
rm -rf "$APP"

# CODE_SIGNING_ALLOWED=NO：让 xcodebuild **不要**签名。
# 原因：工程里是 CODE_SIGN_STYLE=Automatic，会去找开发者账号；CI 上没有账号会直接失败。
# 我们改成"构建时不签、构建完自己签" —— 流程可控，且本地与 CI 完全一致。
# 注意 arm64 的二进制在链接阶段会被自动打上一个 ad-hoc 签名，所以必须用
# `codesign --force` 覆盖掉它，否则 entitlements 不会被带上。
BUILD_LOG="$OUT_DIR/xcodebuild-release.log"
# 判据用**退出码**，不用 grep "BUILD SUCCEEDED"：日志格式会随 Xcode 版本变，
# 而退出码是稳定契约。
if ! xcodebuild \
        -project "$PROJECT" \
        -target KeyLayer \
        -configuration Release \
        build \
        ARCHS="$ARCHS" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    fail "xcodebuild 失败，完整日志见 $BUILD_LOG"
fi
# 构建日志必须留档：CI 上出问题时，grep 过的摘要远远不够
info "构建成功（完整日志：$BUILD_LOG）"
grep -c "warning:" "$BUILD_LOG" | xargs -I{} echo "    编译警告数：{}"
grep "warning:" "$BUILD_LOG" | grep -v "AppIntents" | head -10 | sed 's/^/      /' || true

[ -d "$APP" ] || fail "构建产物不存在：$APP"

# ---------------------------------------------------------------------------
# 2. 产物断言：版本号与架构
# ---------------------------------------------------------------------------

step "2/7 校验产物"

# 断言而不是"看一眼"：版本号是从构建参数注入的，一旦注入链路断掉，
# 产物会静默地带着旧版本号发布出去 —— 这种错必须让流水线直接失败。
PLIST="$APP/Contents/Info.plist"
GOT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
GOT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
[ "$GOT_VERSION" = "$VERSION" ] || fail "版本号注入失败：期望 $VERSION，产物里是 $GOT_VERSION"
[ "$GOT_BUILD" = "$BUILD_NUMBER" ] || fail "构建号注入失败：期望 $BUILD_NUMBER，产物里是 $GOT_BUILD"
info "版本号注入正确：$GOT_VERSION ($GOT_BUILD)"

ARCH_INFO=$(lipo -archs "$APP/Contents/MacOS/NBKey")
info "实际架构：$ARCH_INFO"
for want in $ARCHS; do
    case " $ARCH_INFO " in
        *" $want "*) ;;
        *) fail "缺少架构切片：$want（实际 $ARCH_INFO）" ;;
    esac
done
info "架构切片齐全"

# ---------------------------------------------------------------------------
# 3. 签名
# ---------------------------------------------------------------------------

step "3/7 签名"

# 为什么必须带 entitlements：应用在 Hardened Runtime 下要 dlopen 系统私有框架
# SkyLight（用于切换空间），缺了 com.apple.security.cs.disable-library-validation
# 就会被 library validation 直接拦死。
if [ "$IS_ADHOC" = "1" ]; then
    # ad-hoc 不能带 --timestamp（没有证书就没有可信时间戳服务可签）
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign - "$APP"
else
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
info "签名校验通过"

# 两条断言，防的是"签了名但关键位没带上"这种静默失败：
#   1) 没有 Hardened Runtime 标志 → 公证一定被拒；
#   2) 没有安全时间戳 → 公证也一定被拒。
# 它们不会让 codesign 报错，只会让后面某一步莫名其妙地失败。
SIGN_INFO=$(codesign -dv "$APP" 2>&1)
info "签名属性：$(echo "$SIGN_INFO" | grep -E '^(flags|TeamIdentifier|Timestamp)=' | tr '\n' ' ')"
echo "$SIGN_INFO" | grep -qE 'flags=.*runtime' \
    || fail "产物未启用 Hardened Runtime（options runtime 没生效，公证会失败）"
if [ "$IS_ADHOC" = "0" ]; then
    echo "$SIGN_INFO" | grep -q '^Timestamp=' \
        || fail "缺少安全时间戳（--timestamp 没生效，公证会失败）"
fi

# 断言 entitlements 真的写进去了（不查这一步，就可能发出一个"能装但一切私有 API 都不工作"的包）
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "disable-library-validation"; then
    fail "entitlements 未写入产物（dlopen SkyLight 会失败）"
fi
info "entitlements 已写入：disable-library-validation"

# ---------------------------------------------------------------------------
# 4. 公证 App（可选）
# ---------------------------------------------------------------------------

if can_notarize; then
    step "4/7 公证 App"
    # 先公证 App 本体并 staple：这样用户把 app 从 DMG 拖出来后，**离线**也能通过 Gatekeeper。
    # 只公证 DMG 的话，DMG 上的票据在拖拽后并不跟随 app。
    ZIP="$OUT_DIR/NBKey-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP" || fail "App 公证失败"
    xcrun stapler staple "$APP" || fail "App staple 失败"
    xcrun stapler validate "$APP"
    info "App 已公证并 staple"
    rm -f "$ZIP"
else
    step "4/7 跳过公证"
    info "未提供公证凭据，或当前是 ad-hoc 签名"
fi

# ---------------------------------------------------------------------------
# 5. 生成 DMG
# ---------------------------------------------------------------------------

step "5/7 生成 DMG"

# 用 hdiutil 而不是 create-dmg：它是系统自带的，CI 上不需要 brew install（省 1~2 分钟，
# 也少一个供应链依赖）。代价是没有自定义背景图，换来的是确定性。
STAGE="$OUT_DIR/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/NBKey.app"
ln -s /Applications "$STAGE/Applications"   # 拖拽安装的目标

if [ "$IS_ADHOC" = "1" ]; then
    # ad-hoc 签名过不了 Gatekeeper，用户第一次打开会被拦。把处理办法直接放进 DMG，
    # 否则对方只会看到「已损坏，无法打开」这种几乎无从下手的信息。
    cat > "$STAGE/安装说明.txt" <<'TXT'
NBKey 安装说明
==============

这个包未经 Apple 公证签名（本地构建版本），macOS 首次打开会提示
「无法验证开发者」或「已损坏」。按下面任一方式处理即可：

方式一（推荐，一行命令）
    把 NBKey.app 拖进「应用程序」后，打开「终端」执行：
        xattr -dr com.apple.quarantine /Applications/NBKey.app

方式二（图形界面）
    在「应用程序」里按住 Control 点击 NBKey → 选「打开」→ 在弹窗里再点「打开」。

首次运行还需要授权：系统设置 › 隐私与安全性 › 辅助功能 → 勾选 NBKey。
授权后回到设置窗口会自动重试启动引擎。
TXT
fi

hdiutil create -volname "NBKey" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
info "已生成：$DMG_NAME ($(du -h "$DMG" | cut -f1))"

# ---------------------------------------------------------------------------
# 6. 公证 DMG（可选）+ 整体校验
# ---------------------------------------------------------------------------

step "6/7 校验 DMG"

hdiutil verify "$DMG" > /dev/null || fail "DMG 校验失败"
info "hdiutil verify 通过"

# 真挂载一次，确认里面确实有 app 与 Applications 软链，而不是一个空壳
MOUNT_POINT=$(hdiutil attach "$DMG" -nobrowse -readonly | tail -1 | sed 's/^.*\(\/Volumes\/.*\)$/\1/')
[ -d "$MOUNT_POINT" ] || fail "挂载失败：$MOUNT_POINT"
info "挂载点：$MOUNT_POINT"
[ -d "$MOUNT_POINT/NBKey.app" ] || fail "DMG 里没有 NBKey.app"
[ -L "$MOUNT_POINT/Applications" ] || fail "DMG 里缺少 Applications 软链（用户无处拖拽）"
INNER_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT_POINT/NBKey.app/Contents/Info.plist")
[ "$INNER_VERSION" = "$VERSION" ] || fail "DMG 内 app 版本不符：$INNER_VERSION"
info "DMG 内 app 版本：$INNER_VERSION ✔"
hdiutil detach "$MOUNT_POINT" -quiet || fail "卸载失败"

if can_notarize; then
    notarize "$DMG" || fail "DMG 公证失败"
    xcrun stapler staple "$DMG" || fail "DMG staple 失败"
    xcrun stapler validate "$DMG"
    info "DMG 已公证并 staple"
    # 公证 + staple 之后 spctl 必须放行；不放行说明前面哪一步没生效，直接失败
    spctl -a -t exec -vv "$APP" || fail "spctl 未放行（公证结果没生效）"
else
    # 预期结果：被拒。这里只是**如实记录**，不是失败 —— 发布说明里要据此写安装步骤。
    info "Gatekeeper 评估（ad-hoc 签名预期被拒，属正常）："
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/      /' || true
fi

# SHA256：给下载者一个可自行校验完整性的凭据
( cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256" | sed 's/^/    /' )

# ---------------------------------------------------------------------------
# 7. 汇总
# ---------------------------------------------------------------------------

step "7/7 完成"
# 注意 `codesign -dv` 是**不打印 Authority 的**（那是 -dvvv），只看 -dv 会以为没签上名
AUTHORITY=$(codesign -dvvv "$APP" 2>&1 | grep '^Authority' | head -1 | sed 's/^Authority=//')
info "DMG    : $DMG"
info "SHA256 : $DMG.sha256"
info "签名   : ${AUTHORITY:-ad-hoc（无证书）}"
info "公证   : $(can_notarize && echo '已公证（双击即可打开）' || echo '未公证（用户需先去除隔离标记，见 DMG 内安装说明）')"
