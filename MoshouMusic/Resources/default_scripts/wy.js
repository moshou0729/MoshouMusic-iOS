// 网易云音乐源脚本
//   2026-08 实测可用端点：
//   搜索  music.163.com/api/search/get/web            (官方公开, 无需加密)
//   榜单  music.163.com/api/playlist/detail?id=       (官方公开, result.tracks)
//   播放  music-api.gdstudio.xyz api.php?types=url    (主), 官方 outer/url 302 (兜底)
//   歌词  music.163.com/api/song/lyric                (官方公开)
//   已弃用: weapi(AES+RSA) 自实现 —— iOS14 JSC 上 BigInt 模幂开销大且 player/url 无 cookie 常返回 null
;(function() {
    const source = 'wy'

    lx.send(EVENT_NAMES.inited, {
        sources: ['wy'],
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

    const HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Mobile/15E148 Safari/604.1',
        'Referer': 'https://music.163.com/',
        'Accept': '*/*'
    }

    // 音质 -> gdstudio br
    const BR_MAP = { 'flac': '999', '320k': '320', '128k': '128' }
    // 降级顺序：请求的音质拿不到就往下退
    const BR_CHAIN = { 'flac': ['999', '320', '128'], '320k': ['320', '128'], '128k': ['128'] }

    // 榜单 = 官方歌单 id
    const BOARDS = {
        '1': '19723756',   // 飙升榜
        '2': '3778678',    // 热歌榜
        '3': '3779629',    // 新歌榜
        '4': '2884035'     // 原创榜
    }

    function parseBody(body) {
        try { return JSON.parse(body) } catch (e) { return null }
    }

    function get(url, callback) {
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            const json = parseBody(resp.body)
            if (!json) { callback({ message: '网易云返回非 JSON: HTTP ' + resp.statusCode }, null); return }
            callback(null, json)
        })
    }

    // 兼容 search(artists/album/duration) 与 playlist(ar/al/dt) 两套字段
    function mapSong(item) {
        if (!item) return null
        const arts = item.artists || item.ar || []
        let names = []
        for (let i = 0; i < arts.length; i++) {
            if (arts[i] && arts[i].name) names.push(arts[i].name)
        }
        const album = item.album || item.al || {}
        const ms = item.duration || item.dt || 0
        const id = String(item.id || '')
        if (!id || !item.name) return null
        return {
            songmid: id,
            name: item.name,
            singer: names.length ? names.join('/') : '未知歌手',
            albumName: album.name || '',
            albumId: String(album.id || ''),
            img: album.picUrl || '',
            interval: Math.round(ms / 1000),
            quality: '320k',
            meta: { wyId: id, picId: String(album.picId || album.pic || '') }
        }
    }

    function mapList(arr) {
        const out = []
        for (let i = 0; i < (arr || []).length; i++) {
            const s = mapSong(arr[i])
            if (s) out.push(s)
        }
        return out
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1
        const limit = 30
        const offset = (page - 1) * limit
        const url = 'https://music.163.com/api/search/get/web?csrf_token=' +
            '&s=' + encodeURIComponent(keyword) +
            '&type=1&offset=' + offset + '&total=true&limit=' + limit

        get(url, function(err, json) {
            if (err) { callback(err, null); return }
            const songs = (json.result && json.result.songs) || []
            const list = mapList(songs)
            callback(null, { list: list, total: (json.result && json.result.songCount) || list.length })
        })
    }

    // ==================== 播放链接 ====================
    // 主路径 gdstudio(返回 JSON), 全档位失败后退官方 outer/url 取 302 Location
    function handleMusicUrl(info, callback) {
        const id = String(info.songmid || info.wyId || '')
        if (!id || !/^\d+$/.test(id)) { callback({ message: '无效的网易云歌曲ID' }, null); return }

        const chain = BR_CHAIN[info.quality] || BR_CHAIN['320k']

        function tryBr(idx) {
            if (idx >= chain.length) { outerFallback(); return }
            const url = 'https://music-api.gdstudio.xyz/api.php?types=url&source=netease' +
                '&id=' + id + '&br=' + chain[idx]
            lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
                if (err) { tryBr(idx + 1); return }
                const json = parseBody(resp.body)
                const u = json && json.url ? String(json.url) : ''
                if (u.indexOf('http') === 0) {
                    callback(null, { url: u.replace('http://', 'https://') })
                } else {
                    tryBr(idx + 1)
                }
            })
        }

        function outerFallback() {
            lx.request('https://music.163.com/song/media/outer/url?id=' + id + '.mp3', {
                method: 'GET',
                headers: HEADERS,
                timeout: 15,
                followRedirect: false
            }, function(err, resp) {
                if (err) { callback({ message: '网易云播放链接获取失败' }, null); return }
                const h = resp.headers || {}
                const loc = h['location'] || h['Location'] || ''
                // 下架歌曲会 302 到 music.163.com/404
                if (loc.indexOf('http') === 0 && loc.indexOf('/404') < 0) {
                    callback(null, { url: String(loc).replace('http://', 'https://') })
                } else {
                    callback({ message: '网易云无版权或已下架' }, null)
                }
            })
        }

        tryBr(0)
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        const id = String(info.songmid || info.wyId || '')
        if (!id || !/^\d+$/.test(id)) { callback(null, { lyric: '', tlyric: '' }); return }
        get('https://music.163.com/api/song/lyric?id=' + id + '&lv=1&tv=1&kv=1', function(err, json) {
            if (err || !json) { callback(null, { lyric: '', tlyric: '' }); return }
            const lrc = (json.lrc && json.lrc.lyric) || ''
            const tlrc = (json.tlyric && json.tlyric.lyric) || ''
            callback(null, { lyric: lrc, tlyric: tlrc })
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        const picId = String(info.picId || '')
        if (picId && /^\d+$/.test(picId)) {
            get('https://music-api.gdstudio.xyz/api.php?types=pic&source=netease&id=' + picId + '&size=500',
                function(err, json) {
                    if (err || !json || !json.url) { callback(null, { url: '' }); return }
                    callback(null, { url: String(json.url).replace('http://', 'https://') })
                })
            return
        }
        // 没有 picId 时用歌曲详情补
        const id = String(info.songmid || '')
        if (!id || !/^\d+$/.test(id)) { callback(null, { url: '' }); return }
        get('https://music.163.com/api/song/detail?ids=[' + id + ']', function(err, json) {
            if (err || !json) { callback(null, { url: '' }); return }
            const songs = json.songs || []
            const pic = (songs[0] && songs[0].album && songs[0].album.picUrl) || ''
            callback(null, { url: String(pic).replace('http://', 'https://') })
        })
    }

    // ==================== 榜单 ====================
    function handleBoard(info, callback) {
        const key = String(info.bangId || '')
        const pid = BOARDS[key] || BOARDS['2']   // 默认热歌榜
        get('https://music.163.com/api/playlist/detail?id=' + pid, function(err, json) {
            if (err) { callback(err, null); return }
            const tracks = (json.result && json.result.tracks) || []
            const list = mapList(tracks)
            if (!list.length) { callback({ message: '网易云榜单返回为空' }, null); return }
            callback(null, { list: list.slice(0, 50), total: list.length })
        })
    }
})()
