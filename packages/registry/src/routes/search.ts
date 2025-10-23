import { Router, Request, Response } from 'express';
import { mongoDb, redisClient, logger } from '../server';

export const searchRouter = Router();

// GET /api/search - Search for packages
searchRouter.get('/', async (req: Request, res: Response) => {
    try {
        const query = req.query.q as string || '';
        const page = parseInt(req.query.page as string) || 1;
        const limit = parseInt(req.query.limit as string) || 20;
        const skip = (page - 1) * limit;

        if (!query) {
            return res.status(400).json({ error: 'Query parameter "q" is required' });
        }

        // Check cache first
        const cacheKey = `search:${query}:${page}:${limit}`;
        const cached = await redisClient.get(cacheKey);

        if (cached) {
            logger.info('Returning cached search results', { query });
            return res.json(JSON.parse(cached));
        }

        // Build search query
        const searchQuery = {
            $or: [
                { name: { $regex: query, $options: 'i' } },
                { description: { $regex: query, $options: 'i' } },
                { keywords: { $in: [new RegExp(query, 'i')] } }
            ]
        };

        const packages = await mongoDb
            .collection('packages')
            .find(searchQuery)
            .sort({ downloadCount: -1 })
            .skip(skip)
            .limit(limit)
            .toArray();

        const total = await mongoDb.collection('packages').countDocuments(searchQuery);

        const result = {
            packages,
            query,
            pagination: {
                page,
                limit,
                total,
                totalPages: Math.ceil(total / limit)
            }
        };

        // Cache results for 5 minutes
        await redisClient.setEx(cacheKey, 300, JSON.stringify(result));

        res.json(result);
    } catch (error) {
        logger.error('Error searching packages', { error, query: req.query.q });
        res.status(500).json({ error: 'Search failed' });
    }
});

// GET /api/search/suggestions - Get search suggestions
searchRouter.get('/suggestions', async (req: Request, res: Response) => {
    try {
        const query = req.query.q as string || '';
        const limit = parseInt(req.query.limit as string) || 10;

        if (!query || query.length < 2) {
            return res.json({ suggestions: [] });
        }

        const packages = await mongoDb
            .collection('packages')
            .find({
                name: { $regex: `^${query}`, $options: 'i' }
            })
            .limit(limit)
            .project({ name: 1, description: 1 })
            .toArray();

        res.json({
            suggestions: packages.map(pkg => ({
                name: pkg.name,
                description: pkg.description
            }))
        });
    } catch (error) {
        logger.error('Error getting suggestions', { error, query: req.query.q });
        res.status(500).json({ error: 'Failed to get suggestions' });
    }
});
