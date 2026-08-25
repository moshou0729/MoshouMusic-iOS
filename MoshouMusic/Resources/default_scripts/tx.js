// QQ 音乐源脚本 (真实可用版 · 2026-08 重写)
//
// 为什么重写：
//   旧版用 c.y.qq.com/soso/client_search_cp 搜索，现已被风控——HTTP 200 但 list 恒为空，
//   表现就是「点播放没反应」。u.y.qq.com 的 DoSearchForQQMusicDesktop 同样返回空。
//   QQ 的播放链接需要 vkey 签名，纯前端脚本无法自行生成。
//
// 现在的方案（端点均已实测）：
//   搜索:  https://api.vkeys.cn/v2/music/tencent?word=&page=&num=
//   播放:  https://api.vkeys.cn/v2/music/tencent/geturl?mid=&quality=
//   榜单:  https://u.y.qq.com/cgi-bin/musicu.fcg  (musicToplist.ToplistInfoServer/GetDetail)  官方接口，可直连
//   歌词:  https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?nobase64=1              官方接口，可直连
//
// 注意：iOS 14 的 JavaScriptCore 不支持 async/await 与 Promise，
//       所以全部写成回调式，禁止出现 async 函数。
;(function() {
    const source = 'tx'

    lx.send(EVENT_NAMES.inited, {
        sources: ['tx'],
        qualities: ['128k', '320k', 'flac']
    })

    lx.on(EVENT_NAMES.request, function(data, callback) {
        const { source: src, action, info } = data
        if (src !== source) return

        switch (action) {
            case 'musicSearch': handleSearch(info, callback); break
            case 'musicUrl':    handleMusicUrl(info, callback); break
            case 'lyric':       handleLyric(info, callback); break
            case 'pic':         handlePic(info, callback); break
            case 'musicBoard':  handleBoard(info, callback); break
            default: callback({ message: '未知操作: ' + action }, null)
        }
    })

    const API = 'https://api.vkeys.cn/v2/music/tencent'

    const HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15'
    }
    const QQ_HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15',
        'Referer': 'https://y.qq.com/portal/player.html'
    }

    function parseJSON(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) { return null }
    }

    function joinSingers(list) {
        if (!list || !list.length) return ''
        const names = []
        for (let i = 0; i < list.length; i++) {
            const n = list[i] && (list[i].name || list[i].title)
            if (n) names.push(n)
        }
        return names.join('/')
    }

    // vkeys 的 quality: 4=标准128k, 8=极高320k, 11=flac无损
    function qualityToLevel(quality) {
        switch (quality) {
            case 'flac': return 11
            case '320k': return 8
            default:     return 4
        }
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1

        const url = API + '?word=' + encodeURIComponent(keyword) +
            '&page=' + page + '&num=30'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            if (!result || result.code !== 200 || !result.data) {
                callback({ message: 'QQ 搜索失败: ' + ((result && result.message) || ('HTTP ' + resp.statusCode)) }, null)
                return
            }

            const arr = result.data instanceof Array ? result.data : [result.data]
            const list = []
            for (let i = 0; i < arr.length; i++) {
                const item = arr[i]
                if (!item || !item.mid) continue
                list.push({
                    songmid: String(item.mid),
                    name: item.song || '未知歌曲',
                    singer: item.singer || joinSingers(item.singer_list) || '未知歌手',
                    albumName: item.album || '',
                    albumId: '',
                    img: item.cover || '',
                    interval: intervalToSeconds(item.interval),
                    quality: '320k',
                    // 播放/歌词都要用 mid，放进 meta 一并带下去
                    meta: { mid: String(item.mid), songId: String(item.id || '') }
                })
            }

            callback(null, { list: list, total: list.length })
        })
    }

    // vkeys 返回的 interval 形如 "3分35秒"
    function intervalToSeconds(v) {
        if (typeof v === 'number') return v
        if (!v) return 0
        const m = String(v).match(/(\d+)\s*分\s*(\d+)\s*秒/)
        if (m) return parseInt(m[1], 10) * 60 + parseInt(m[2], 10)
        const n = parseInt(v, 10)
        return isNaN(n) ? 0 : n
    }

    // ==================== 播放链接 ====================
    function requestUrl(mid, level, callback) {
        const url = API + '/geturl?mid=' + encodeURIComponent(mid) + '&quality=' + level

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 20 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            if (!result || result.code !== 200 || !result.data) {
                callback({ message: 'QQ 取链接失败: ' + ((result && result.message) || ('HTTP ' + resp.statusCode)) }, null)
                return
            }
            const u = result.data.url
            if (!u || String(u).indexOf('http') !== 0) {
                callback({ message: 'QQ 未返回可用链接（可能是纯付费歌曲）' }, null)
                return
            }
            callback(null, String(u))
        })
    }

    function handleMusicUrl(info, callback) {
        // mid 优先从 meta 透传的字段取，其次退回 songmid
        const mid = info.mid || info.songmid
        if (!mid) { callback({ message: '缺少歌曲 mid' }, null); return }

        const level = qualityToLevel(info.quality || '320k')

        requestUrl(mid, level, function(err, url) {
            if (!err) { callback(null, { url: url }); return }
            // 高音质拿不到就降级到标准音质再试一次
            if (level !== 4) {
                requestUrl(mid, 4, function(err2, url2) {
                    if (err2) { callback(err2, null); return }
                    callback(null, { url: url2 })
                })
                return
            }
            callback(err, null)
        })
    }

    // ==================== 排行榜 ====================
    // topId: 26=热歌榜 / 27=新歌榜 / 4=流行指数榜
    function handleBoard(info, callback) {
        const topId = (info && info.bangId) ? parseInt(info.bangId, 10) : 26
        const payload = {
            detail: {
                module: 'musicToplist.ToplistInfoServer',
                method: 'GetDetail',
                param: { topId: isNaN(topId) ? 26 : topId, num: 50 }
            }
        }
        const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?data=' +
            encodeURIComponent(JSON.stringify(payload))

        lx.request(url, { method: 'GET', headers: QQ_HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { fallbackBoard(callback); return }

            const result = parseJSON(resp.body)
            const songs = result && result.detail && result.detail.data &&
                          result.detail.data.songInfoList
            if (!songs || !songs.length) { fallbackBoard(callback); return }

            const list = []
            for (let i = 0; i < songs.length; i++) {
                const s = songs[i]
                if (!s || !s.mid) continue
                list.push({
                    songmid: String(s.mid),
                    name: s.name || s.title || '未知歌曲',
                    singer: joinSingers(s.singer) || '未知歌手',
                    albumName: (s.album && s.album.name) || '',
                    albumId: (s.album && s.album.mid) || '',
                    img: (s.album && s.album.mid)
                        ? 'https://y.qq.com/music/photo_new/T002R300x300M000' + s.album.mid + '.jpg'
                        : '',
                    interval: s.interval || 0,
                    quality: '320k',
                    meta: { mid: String(s.mid), songId: String(s.id || '') }
                })
            }

            if (!list.length) { fallbackBoard(callback); return }
            callback(null, { list: list, total: list.length })
        })
    }

    // 官方榜单不可达时，退回一次热门关键词搜索（串行，不并发）
    const HOT = ['热门', '2026新歌', '周杰伦']

    function fallbackBoard(callback) {
        let idx = 0
        function tryNext() {
            if (idx >= HOT.length) {
                callback({ message: 'QQ 榜单与兜底搜索均无结果' }, null)
                return
            }
            handleSearch({ keyword: HOT[idx++], page: 1 }, function(err, data) {
                if (!err && data && data.list && data.list.length) {
                    callback(null, { list: data.list.slice(0, 30), total: data.list.length })
                } else {
                    tryNext()
                }
            })
        }
        tryNext()
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        const mid = info.mid || info.songmid
        if (!mid) { callback({ message: '缺少歌曲 mid' }, null); return }

        const url = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg' +
            '?songmid=' + encodeURIComponent(mid) + '&g_tk=5381&format=json&nobase64=1'

        lx.request(url, { method: 'GET', headers: QQ_HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            if (!result || result.retcode !== 0) {
                callback({ message: 'QQ 歌词获取失败' }, null)
                return
            }
            callback(null, {
                lyric: result.lyric || '',
                tlyric: result.trans || ''
            })
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        // QQ 封面可由 albummid 直接拼出，无需额外请求
        if (info.albumId) {
            callback(null, {
                url: 'https://y.qq.com/music/photo_new/T002R500x500M000' + info.albumId + '.jpg'
            })
            return
        }

        const mid = info.mid || info.songmid
        if (!mid) { callback(null, { url: '' }); return }

        const url = API + '/geturl?mid=' + encodeURIComponent(mid) + '&quality=4'
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(null, { url: '' }); return }
            const result = parseJSON(resp.body)
            const cover = result && result.data && result.data.cover
            callback(null, { url: cover || '' })
        })
    }
})()
