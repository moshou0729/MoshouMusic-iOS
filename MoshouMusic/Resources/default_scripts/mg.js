// 咪咕音乐源脚本 (真实可用版 · 2026-08 重写)
//
// 为什么重写：
//   旧版用 m.music.migu.cn/migu/remoting/scr_search_tag 搜索，该域名现在整站 301，
//   请求拿不到任何数据，表现就是「咪咕没有内容」。
//
// 现在的方案（端点均已实测）：
//   搜索:  https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do
//   播放:  https://app.pd.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listenSong.do
//          ★ 该接口返回 302，真实直链在 Location 响应头里；
//            所以请求时必须带 followRedirect:false，否则拿不到直链只能拿到音频流本身。
//          ★ channel 参数必填（不是 channelCode），缺了会报「参数校验失败」。
//   榜单:  https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do?columnId=
//   歌词:  搜索结果里的 lyricUrl 直接下载
//
// 播放依赖 contentId + copyrightId 两个 ID，所以搜索结果必须把它们放进 meta 带下来。
// iOS 14 的 JavaScriptCore 不支持 async/await 与 Promise，全部写成回调式。
;(function() {
    const source = 'mg'

    lx.send(EVENT_NAMES.inited, {
        sources: ['mg'],
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
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15',
        'Referer': 'https://m.music.migu.cn/',
        'channel': '0146921'
    }

    // 匿名 userId，咪咕的试听接口只做格式校验，不校验归属
    const USER_ID = '15548614588710179085069'

    function parseJSON(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) { return null }
    }

    // 响应头大小写不统一，做一次不敏感查找
    function header(resp, name) {
        if (!resp || !resp.headers) return ''
        const h = resp.headers
        const lower = String(name).toLowerCase()
        if (h[name]) return h[name]
        if (h[lower]) return h[lower]
        for (const k in h) {
            if (String(k).toLowerCase() === lower) return h[k]
        }
        return ''
    }

    function firstName(arr) {
        if (!arr || !arr.length) return ''
        const names = []
        for (let i = 0; i < arr.length; i++) {
            const n = arr[i] && arr[i].name
            if (n) names.push(n)
        }
        return names.join('/')
    }

    function firstImg(imgs) {
        if (!imgs || !imgs.length) return ''
        // 优先大图
        for (let i = imgs.length - 1; i >= 0; i--) {
            if (imgs[i] && imgs[i].img) return imgs[i].img
        }
        return ''
    }

    // 音质 → toneFlag
    function qualityToTone(quality) {
        switch (quality) {
            case 'flac': return 'SQ'
            case '320k': return 'HQ'
            default:     return 'PQ'
        }
    }

    // 把接口返回的一条歌曲对象归一化为 App 需要的格式
    function normalizeSong(o) {
        if (!o) return null
        const contentId = o.contentId || o.songId || ''
        const copyrightId = o.copyrightId || ''
        if (!contentId && !copyrightId) return null

        return {
            songmid: String(contentId || copyrightId),
            name: o.songName || o.name || '未知歌曲',
            singer: firstName(o.singers) || firstName(o.artists) || o.singerName || '未知歌手',
            albumName: firstName(o.albums) || o.album || '',
            albumId: String(o.albumId || ''),
            img: firstImg(o.imgItems) || firstImg(o.albumImgs) || '',
            interval: parseInt(o.duration || '0', 10) || 0,
            quality: '320k',
            meta: {
                contentId: String(contentId || ''),
                copyrightId: String(copyrightId || ''),
                lyricUrl: String(o.lyricUrl || '')
            }
        }
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1

        const url = 'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do' +
            '?ua=Android_migu&version=5.0.1' +
            '&text=' + encodeURIComponent(keyword) +
            '&pageNo=' + page + '&pageSize=30' +
            '&searchSwitch=' + encodeURIComponent('{"song":1,"album":0,"singer":0,"tagSong":0,"mvSong":0,"songlist":0,"bestShow":1}')

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            const arr = result && result.songResultData && result.songResultData.result
            if (!arr || !arr.length) {
                callback({ message: '咪咕搜索无结果 (HTTP ' + resp.statusCode + ')' }, null)
                return
            }

            const list = []
            for (let i = 0; i < arr.length; i++) {
                const s = normalizeSong(arr[i])
                if (s) list.push(s)
            }

            if (!list.length) {
                callback({ message: '咪咕搜索结果解析后为空' }, null)
                return
            }
            callback(null, { list: list, total: list.length })
        })
    }

    // ==================== 播放链接 ====================
    function requestUrl(contentId, copyrightId, toneFlag, callback) {
        const url = 'https://app.pd.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listenSong.do' +
            '?channel=0' +
            '&contentId=' + encodeURIComponent(contentId) +
            '&copyrightId=' + encodeURIComponent(copyrightId) +
            '&netType=01&resourceType=2' +
            '&toneFlag=' + toneFlag +
            '&userId=' + USER_ID

        // followRedirect:false → 让宿主把 302 原样交回，真实直链在 Location 头
        lx.request(url, {
            method: 'GET',
            headers: HEADERS,
            timeout: 20,
            followRedirect: false
        }, function(err, resp) {
            if (err) { callback(err, null); return }

            const location = header(resp, 'Location')
            if (location && String(location).indexOf('http') === 0) {
                callback(null, String(location))
                return
            }

            // 少数情况下直接返回 JSON 报错
            const result = parseJSON(resp.body)
            const msg = (result && (result.info || result.msg)) || ('HTTP ' + resp.statusCode)
            callback({ message: '咪咕取链接失败: ' + msg }, null)
        })
    }

    function handleMusicUrl(info, callback) {
        const contentId = info.contentId || info.songmid
        const copyrightId = info.copyrightId || info.songmid
        if (!contentId && !copyrightId) {
            callback({ message: '缺少咪咕歌曲 ID' }, null)
            return
        }

        const quality = info.quality || '320k'
        // 逐级降级：目标音质 → HQ → PQ
        const tones = []
        const target = qualityToTone(quality)
        tones.push(target)
        if (target !== 'HQ') tones.push('HQ')
        if (target !== 'PQ') tones.push('PQ')

        let idx = 0
        function tryNext() {
            if (idx >= tones.length) {
                callback({ message: '咪咕所有音质均无法播放' }, null)
                return
            }
            const tone = tones[idx++]
            requestUrl(contentId, copyrightId, tone, function(err, url) {
                if (!err && url) { callback(null, { url: url }); return }
                tryNext()
            })
        }
        tryNext()
    }

    // ==================== 排行榜 ====================
    // columnId: 27553319=尖叫新歌榜 / 27186466=尖叫热歌榜 / 19863022=尖叫原创榜
    function handleBoard(info, callback) {
        const columnId = (info && info.bangId) ? String(info.bangId) : '27553319'

        const url = 'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do' +
            '?needSimple=00&columnId=' + columnId

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { fallbackBoard(callback); return }

            const result = parseJSON(resp.body)
            const contents = result && result.columnInfo && result.columnInfo.contents
            if (!contents || !contents.length) { fallbackBoard(callback); return }

            const list = []
            for (let i = 0; i < contents.length; i++) {
                const s = normalizeSong(contents[i] && contents[i].objectInfo)
                if (s) list.push(s)
            }

            if (!list.length) { fallbackBoard(callback); return }
            callback(null, { list: list, total: list.length })
        })
    }

    const HOT = ['热门歌曲', '新歌', '周杰伦']

    function fallbackBoard(callback) {
        let idx = 0
        function tryNext() {
            if (idx >= HOT.length) {
                callback({ message: '咪咕榜单与兜底搜索均无结果' }, null)
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
        // 搜索时已把 lyricUrl 存进 meta，直接下载最省事
        if (info.lyricUrl && String(info.lyricUrl).indexOf('http') === 0) {
            lx.request(info.lyricUrl, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
                if (err) { callback(null, { lyric: '', tlyric: '' }); return }
                callback(null, { lyric: resp.body || '', tlyric: '' })
            })
            return
        }

        // 没有 lyricUrl 时，用歌曲详情接口补一次
        const copyrightId = info.copyrightId || info.songmid
        if (!copyrightId) { callback(null, { lyric: '', tlyric: '' }); return }

        const url = 'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do' +
            '?resourceId=' + encodeURIComponent(copyrightId) + '&resourceType=2'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(null, { lyric: '', tlyric: '' }); return }
            const result = parseJSON(resp.body)
            const res = result && result.resource && result.resource[0]
            const lyricUrl = res && res.lyricUrl
            if (!lyricUrl) { callback(null, { lyric: '', tlyric: '' }); return }

            lx.request(lyricUrl, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err2, resp2) {
                if (err2) { callback(null, { lyric: '', tlyric: '' }); return }
                callback(null, { lyric: resp2.body || '', tlyric: '' })
            })
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        const copyrightId = info.copyrightId || info.songmid
        if (!copyrightId) { callback(null, { url: '' }); return }

        const url = 'https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do' +
            '?resourceId=' + encodeURIComponent(copyrightId) + '&resourceType=2'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(null, { url: '' }); return }
            const result = parseJSON(resp.body)
            const res = result && result.resource && result.resource[0]
            const pic = res ? (firstImg(res.albumImgs) || firstImg(res.imgItems)) : ''
            callback(null, { url: pic })
        })
    }
})()
